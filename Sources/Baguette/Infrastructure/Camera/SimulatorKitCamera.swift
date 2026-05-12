import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import ObjectiveC

/// Production `Camera` — injects image frames into a simulator's
/// camera surface via SimulatorKit's `SimDeviceIO` descriptors.
///
/// The simulator exposes camera ports alongside framebuffer ports on
/// its `SimDeviceIO` object. We find the `com.apple.camera.front`
/// (or `com.apple.camera.back`) descriptor and push `IOSurface`
/// frames into it, which the guest's `AVCaptureDevice` picks up as
/// live camera input.
///
/// Approach: resolve the device's IO object, find camera descriptors,
/// and use the `pushSurface:` / `pushPixelBuffer:` selector on the
/// descriptor to inject frames. This mirrors how Xcode's own
/// simulated camera feature works internally.
final class SimulatorKitCamera: Camera, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "baguette.camera", qos: .userInteractive)

    private var ioClient: NSObject?
    private var cameraDescriptor: NSObject?
    private var videoLoopTask: Task<Void, Never>?
    private var warmed = false

    init(udid: String, host: any DeviceHost) {
        self.udid = udid
        self.host = host
    }

    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    // MARK: - Camera protocol

    func injectImage(_ image: CGImage) throws {
        let desc = try ensureWarm()
        let surface = try createIOSurface(from: image)
        try pushSurface(surface, to: desc)
    }

    func injectVideo(url: URL) throws {
        let desc = try ensureWarm()
        videoLoopTask?.cancel()
        videoLoopTask = Task { [weak self] in
            await self?.videoLoop(url: url, descriptor: desc)
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        videoLoopTask?.cancel()
        videoLoopTask = nil
        cameraDescriptor = nil
        ioClient = nil
        warmed = false
    }

    // MARK: - IO surface creation

    private func createIOSurface(from image: CGImage) throws -> IOSurface {
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

    // MARK: - frame push

    private func pushSurface(_ surface: IOSurface, to desc: NSObject) throws {
        // Try pushIOSurface: first (available on newer SimulatorKit)
        let pushSurfaceSel = NSSelectorFromString("pushIOSurface:")
        if desc.responds(to: pushSurfaceSel) {
            desc.perform(pushSurfaceSel, with: surface)
            return
        }

        // Fallback: sendIOSurface: (older SimulatorKit variants)
        let sendSurfaceSel = NSSelectorFromString("sendIOSurface:")
        if desc.responds(to: sendSurfaceSel) {
            desc.perform(sendSurfaceSel, with: surface)
            return
        }

        // Fallback: class_getMethodImplementation for typed dispatch
        let setSel = NSSelectorFromString("setFramebufferSurface:")
        if desc.responds(to: setSel) {
            desc.perform(setSel, with: surface)
            return
        }

        throw CameraError.injectionFailed(
            reason: "no push/send IOSurface selector found on camera descriptor"
        )
    }

    // MARK: - video loop

    private func videoLoop(url: URL, descriptor: NSObject) async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return }

        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 30.0
        let frameInterval: UInt64 = nominalFPS > 0
            ? UInt64(1_000_000_000.0 / Double(nominalFPS))
            : 33_333_333  // ~30 fps fallback

        while !Task.isCancelled {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(output)
            guard reader.startReading() else { return }

            while !Task.isCancelled, reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer(),
                      let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                else { continue }

                CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
                if let surface = CVPixelBufferGetIOSurface(imageBuffer) {
                    let ioSurface = unsafeBitCast(surface, to: IOSurface.self)
                    try? pushSurface(ioSurface, to: descriptor)
                }
                CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

                try? await Task.sleep(nanoseconds: frameInterval)
            }

            reader.cancelReading()
        }
    }

    // MARK: - warm-up

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
