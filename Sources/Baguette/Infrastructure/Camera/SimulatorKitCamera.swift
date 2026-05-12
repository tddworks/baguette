import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import ObjectiveC

/// Wrapper that makes a non-`Sendable` value safe to capture in
/// `@Sendable` closures. The caller is responsible for ensuring
/// the wrapped value is thread-safe in practice.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    /// The wrapped value.
    let value: T
    /// Wrap `value` for `@Sendable` capture.
    init(_ value: T) { self.value = value }
}

/// Production `Camera` — orchestrates image and video injection into
/// a simulator's camera surface via SimulatorKit's `SimDeviceIO`
/// descriptors.
///
/// Orchestration (device resolution, descriptor discovery, video loop
/// lifecycle) lives here. Irreducible ObjC selector calls are
/// delegated to `SurfacePusher`; AVFoundation decoding is delegated
/// to `VideoDecoder`. This split lets tests drive the orchestrator
/// with `MockSurfacePusher` / `MockVideoDecoder` without a live
/// simulator.
final class SimulatorKitCamera: Camera, @unchecked Sendable {
    /// Simulator UDID this camera targets.
    private let udid: String
    /// Device host for resolving the live `SimDevice` object.
    private let host: any DeviceHost
    /// Collaborator that pushes `IOSurface` frames to the descriptor.
    private let pusher: any SurfacePusher
    /// Collaborator that decodes video files into `IOSurface` frames.
    private let decoder: any VideoDecoder
    /// Guards all mutable state (`ioClient`, `cameraDescriptor`,
    /// `videoLoopTask`, `warmed`) for thread safety.
    private let lock = NSLock()

    /// Cached `SimDeviceIO` object for this simulator.
    private var ioClient: NSObject?
    /// Cached camera port descriptor discovered during warm-up.
    private var cameraDescriptor: NSObject?
    /// Background task running the video decode-and-push loop.
    private var videoLoopTask: Task<Void, Never>?
    /// True once the camera descriptor has been resolved.
    private var warmed = false

    /// Create a camera injection pipeline for the given simulator.
    ///
    /// - Parameters:
    ///   - udid: Simulator UDID to target.
    ///   - host: Device host for resolving the live `SimDevice` object.
    ///   - pusher: Collaborator that pushes `IOSurface` frames via ObjC selectors.
    ///   - decoder: Collaborator that decodes video files into `IOSurface` frames.
    init(
        udid: String,
        host: any DeviceHost,
        pusher: any SurfacePusher = SimulatorKitSurfacePusher(),
        decoder: any VideoDecoder = AVFoundationVideoDecoder()
    ) {
        self.udid = udid
        self.host = host
        self.pusher = pusher
        self.decoder = decoder
    }

    /// Look up the underlying `SimDevice` `NSObject` for this UDID.
    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    // MARK: - Camera protocol

    /// Push a single still frame into the simulator's camera feed.
    /// Converts the image to a BGRA `IOSurface` and dispatches it
    /// to the camera descriptor synchronously.
    func injectImage(_ image: CGImage) throws {
        let desc = try ensureWarm()
        let surface = try Self.createIOSurface(from: image)
        try pusher.push(surface, to: desc)
    }

    /// Start looping video frames from `url` into the camera feed.
    /// Cancels any previously active video loop. Errors during
    /// decoding are logged; the loop retries from the beginning of
    /// the file until cancelled via `stop()`.
    func injectVideo(url: URL) throws {
        let desc = try ensureWarm()
        let pusher = self.pusher

        // NSObject is not Sendable but the descriptor is thread-safe
        // in practice (SimulatorKit serialises calls internally).
        let descriptorRef = UncheckedSendableBox(desc)

        lock.lock()
        videoLoopTask?.cancel()
        videoLoopTask = Task { [weak self, decoder] in
            do {
                try await decoder.decodeLoop(url: url) { surface in
                    try pusher.push(surface, to: descriptorRef.value)
                }
            } catch is CancellationError {
                // Normal shutdown via stop().
            } catch {
                log("[camera] video loop error: \(error)")
                self?.stop()
            }
        }
        lock.unlock()
    }

    /// Tear down the camera pipeline, cancel any active video loop,
    /// and release cached SimulatorKit handles. Safe to call
    /// multiple times — subsequent calls are no-ops.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        videoLoopTask?.cancel()
        videoLoopTask = nil
        cameraDescriptor = nil
        ioClient = nil
        warmed = false
    }

    // MARK: - IOSurface creation

    /// Convert a `CGImage` to a BGRA `IOSurface` suitable for
    /// injection into a SimulatorKit camera descriptor.
    static func createIOSurface(from image: CGImage) throws -> IOSurface {
        let w = image.width
        let h = image.height
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel

        let properties: [IOSurfacePropertyKey: Any] = [
            .width: w,
            .height: h,
            .bytesPerElement: bytesPerPixel,
            .bytesPerRow: bytesPerRow,
            .allocSize: bytesPerRow * h,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]

        guard let surface = IOSurface(properties: properties) else {
            throw CameraError.injectionFailed(reason: "IOSurface allocation failed")
        }

        surface.lock(options: [], seed: nil)
        let base = surface.baseAddress
        let ctx = CGContext(
            data: base,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        surface.unlock(options: [], seed: nil)

        return surface
    }

    // MARK: - warm-up

    /// Lazily resolve the simulator's camera descriptor. Thread-safe
    /// via `lock` — multiple callers share the same cached descriptor
    /// once warmed.
    @discardableResult
    private func ensureWarm() throws -> NSObject {
        lock.lock()
        defer { lock.unlock() }
        if let desc = cameraDescriptor { return desc }

        guard let device = resolveDevice() else {
            throw CameraError.deviceNotFound(udid: udid)
        }

        guard let io = device.perform(NSSelectorFromString("io"))?
            .takeUnretainedValue() as? NSObject
        else {
            throw CameraError.ioUnavailable
        }
        self.ioClient = io

        io.perform(NSSelectorFromString("updateIOPorts"))

        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw CameraError.cameraDescriptorNotFound
        }

        let pidSel = NSSelectorFromString("portIdentifier")
        let descSel = NSSelectorFromString("descriptor")

        let cameraIdentifiers = [
            "com.apple.camera.front",
            "com.apple.camera.back",
            "com.apple.camera",
        ]

        for port in ports where port.responds(to: pidSel) {
            guard let pid = port.perform(pidSel)?.takeUnretainedValue() else { continue }
            let pidStr = "\(pid)"
            if cameraIdentifiers.contains(where: { pidStr.contains($0) }),
               port.responds(to: descSel),
               let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject
            {
                cameraDescriptor = desc
                warmed = true
                log("[camera] attached to \(pidStr)")
                return desc
            }
        }

        throw CameraError.cameraDescriptorNotFound
    }
}
