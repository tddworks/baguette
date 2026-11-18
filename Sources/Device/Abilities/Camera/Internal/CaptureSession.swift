import AVFoundation
import CoreVideo
import Foundation
import Mockable

/// A Mac camera's capture session — AVFoundation's `AVCaptureSession`,
/// reduced to the calls the capture makes. It decides nothing: which
/// preset, what size and what a picture becomes belong to
/// `HostVideoCapture`. The real one is `AVFoundationCaptureSession`.
@Mockable
protocol CaptureSession: AnyObject, Sendable {
    /// Whether the session can run at this preset.
    func supports(_ preset: AVCaptureSession.Preset) -> Bool
    /// Run the camera with this unique ID at `preset` (or its own when
    /// nil), emitting BGRA pictures of `width` × `height`, late ones
    /// discarded. `onPicture` gets each with its presentation time in
    /// seconds, on the session's queue. False when no such camera is
    /// attached; throws when it can't be opened.
    func run(
        camera uniqueID: String, preset: AVCaptureSession.Preset?, width: Int, height: Int,
        onPicture: @escaping @Sendable (CVPixelBuffer, Double) -> Void
    ) throws -> Bool
    /// Stop running and detach the camera.
    func stop()
}
