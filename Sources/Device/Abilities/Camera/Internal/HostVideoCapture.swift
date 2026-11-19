import AVFoundation
import CoreVideo
import Foundation

/// The `VideoCapture` on a Mac camera. It decides; the `CaptureSession`
/// only captures: which preset and size the camera runs at, and how each
/// picture becomes a `RawBGRAFrame`.
public final class HostVideoCapture: VideoCapture, @unchecked Sendable {
    /// Pin the output size to the shared-buffer canvas cap. Without it
    /// AVFoundation emits at the camera's *native* resolution (1080p / 4K
    /// on modern FaceTime HD), which exceeds
    /// `SharedFrameLayout.maxCanvasWidth/Height` (1280×1280) and every
    /// frame gets rejected before reaching the dylib's reader. SimCamMac
    /// does the same — `.hd1280x720` preset + pinned width/height — see
    /// asc-pro/SimCam/AVCameraSource.
    static let width = 1280
    static let height = 720
    /// The most specific preset up to 1280×720 first. Continuity Camera
    /// devices don't advertise every preset; degrade gracefully.
    static let presets: [AVCaptureSession.Preset] = [.hd1280x720, .high, .medium]

    private let session: any CaptureSession
    private let lock = NSLock()
    private var onFrame: (@Sendable (RawBGRAFrame) -> Void)?

    public convenience init() { self.init(session: AVFoundationCaptureSession()) }

    init(session: any CaptureSession) { self.session = session }

    public func start(
        deviceUniqueID: String,
        onFrame: @escaping @Sendable (RawBGRAFrame) -> Void
    ) async throws {
        lock.withLock { self.onFrame = onFrame }
        let preset = Self.presets.first(where: session.supports)
        let running: Bool
        do {
            running = try session.run(
                camera: deviceUniqueID, preset: preset, width: Self.width, height: Self.height
            ) { [weak self] picture, seconds in self?.deliver(picture, at: seconds) }
        } catch {
            lock.withLock { self.onFrame = nil }
            throw error
        }
        guard running else {
            lock.withLock { self.onFrame = nil }
            throw HostVideoCaptureError.deviceUnavailable(uid: deviceUniqueID)
        }
    }

    public func stop() async {
        session.stop()
        lock.withLock { onFrame = nil }
    }

    /// One picture, handed on as a raw frame while its bytes are locked.
    private func deliver(_ picture: CVPixelBuffer, at seconds: Double) {
        guard let onFrame = lock.withLock({ onFrame }) else { return }
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(picture) else { return }
        onFrame(RawBGRAFrame(
            baseAddress: UnsafeRawPointer(base),
            width: UInt32(CVPixelBufferGetWidth(picture)),
            height: UInt32(CVPixelBufferGetHeight(picture)),
            bytesPerRow: CVPixelBufferGetBytesPerRow(picture),
            timestampMs: UInt32(truncatingIfNeeded: Int64(seconds * 1000))))
    }
}

public enum HostVideoCaptureError: Error, CustomStringConvertible {
    case deviceUnavailable(uid: String)

    public var description: String {
        switch self {
        case .deviceUnavailable(let uid):
            return "no AVCaptureDevice with unique ID '\(uid)'"
        }
    }
}
