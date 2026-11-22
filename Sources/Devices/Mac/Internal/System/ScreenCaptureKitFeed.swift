import BaguetteDevice
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// One display's pictures through ScreenCaptureKit, as BGRA surfaces at the
/// size asked. Integration-only: which pictures are handed on, and starting
/// again, are `MacScreen`'s.
final class ScreenCaptureKitFeed: NSObject, DisplayFeed, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "baguette.mac.feed", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var onPicture: (@Sendable (FeedPicture) -> Void)?
    private var onEnd: (@Sendable () -> Void)?

    func start(display: UInt32, sizing: @escaping @Sendable (Size, Double) -> Size,
               onPicture: @escaping @Sendable (FeedPicture) -> Void,
               onEnd: @escaping @Sendable () -> Void) throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenRecordingRefused()
        }
        let content: SCShareableContent = try wait { done in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { done($0, $1) }
        }
        guard let target = content.displays.first(where: { $0.displayID == display }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "display \(display) is gone"])
        }
        let filter = SCContentFilter(display: target, excludingWindows: [])
        let size = sizing(Size(width: filter.contentRect.width, height: filter.contentRect.height),
                          Double(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.showsCursor = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock { self.stream = stream; self.onPicture = onPicture; self.onEnd = onEnd }
        let _: Bool = try wait { done in stream.startCapture { done($0 == nil ? true : nil, $0) } }
    }

    func stop() {
        let stream = lock.withLock {
            defer { self.stream = nil; onPicture = nil; onEnd = nil }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let onPicture = lock.withLock({ onPicture }) else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = (info?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        let surface = CMSampleBufferGetImageBuffer(buffer)
            .flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
            .map { unsafeDowncast($0, to: IOSurface.self) }
        onPicture(FeedPicture(surface: surface, complete: status == .complete))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log("[mac] screen feed ended: \(error.localizedDescription)")
        let onEnd = lock.withLock {
            defer { self.stream = nil; onPicture = nil; self.onEnd = nil }
            return self.onEnd
        }
        onEnd?()
    }

    /// ScreenCaptureKit answers on a queue of its own; `Screen.start` waits. Five seconds at most.
    private func wait<T>(_ ask: (@escaping @Sendable (T?, (any Error)?) -> Void) -> Void) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: (T?, (any Error)?) = (nil, nil)
        ask { value, error in answer = (value, error); done.signal() }
        guard done.wait(timeout: .now() + 5) == .success else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit didn't answer in 5 s"])
        }
        if let value = answer.0 { return value }
        throw answer.1 ?? CocoaError(.userCancelled)
    }
}
