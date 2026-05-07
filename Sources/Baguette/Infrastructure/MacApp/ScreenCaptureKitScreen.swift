import Foundation
import IOSurface
import CoreVideo
import CoreMedia
import ScreenCaptureKit

/// Production `Screen` for native macOS apps — bridges
/// `ScreenCaptureKit`'s `SCStream` (async, sample-buffer-based)
/// onto the synchronous `Screen.start(onFrame:)` callback the
/// existing `Stream` pipeline expects.
///
/// We capture **the frontmost window of the target app** filtered
/// by PID via `SCContentFilter(desktopIndependentWindow:)`. The
/// SCStream delivers `CMSampleBuffer`s on its sample-handler queue;
/// we extract `CVPixelBuffer` → `IOSurface` and forward the surface
/// straight into the existing MJPEG / AVCC encoders. Stream-config
/// (bitrate / fps / scale) reuses the iOS pipeline unchanged.
///
/// This is integration-only — `SCShareableContent.current` is async
/// and there's no sync alternative. Setup runs on a Task spawned
/// from `start(onFrame:)`; if it fails (e.g. TCC denied, app has
/// no on-screen window), no frames arrive and a single error log
/// line surfaces the cause.
final class ScreenCaptureKitScreen: Screen, @unchecked Sendable {
    private let pid: pid_t
    private var stream: SCStream?
    private var output: SampleHandler?

    init(pid: pid_t) {
        self.pid = pid
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        Task { [pid, weak self] in
            do {
                try await self?.beginCapture(pid: pid, onFrame: onFrame)
            } catch {
                logErr("[mac-screen] capture failed: \(error)")
            }
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        self.output = nil
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
    }

    // MARK: - private

    private func beginCapture(
        pid: pid_t,
        onFrame: @escaping @Sendable (IOSurface) -> Void
    ) async throws {
        // 1. Resolve the target app's frontmost window from the
        //    shareable content. `excludingDesktopWindows: true` skips
        //    the Finder desktop; `onScreenWindowsOnly: true` skips
        //    minimized / off-screen windows.
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid
        }) else {
            throw MacAppError.notFound(bundleID: "pid:\(pid)")
        }

        // 2. Filter to that single window so the frame is a tight
        //    crop without surrounding screen content.
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // 3. Configuration — match the existing stream pipeline's
        //    expectations. Pixel format BGRA so CVPixelBuffer →
        //    IOSurface is a single-zero-copy cast.
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)   // capture at retina
        config.height = Int(window.frame.height * 2)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = true

        let handler = SampleHandler(onFrame: onFrame)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(
            handler,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(
                label: "baguette.mac-screen",
                qos: .userInteractive
            )
        )
        try await stream.startCapture()

        self.stream = stream
        self.output = handler
        log("[mac-screen] capturing pid=\(pid) window=\(window.title ?? "<untitled>")")
    }
}

/// `SCStreamOutput` delegate that pulls the `IOSurface` out of every
/// `CMSampleBuffer` and forwards it. Marked unchecked-Sendable because
/// it only reads its `onFrame` closure (constant after init).
private final class SampleHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    let onFrame: @Sendable (IOSurface) -> Void

    init(onFrame: @escaping @Sendable (IOSurface) -> Void) {
        self.onFrame = onFrame
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return
        }
        onFrame(surface as IOSurface)
    }
}
