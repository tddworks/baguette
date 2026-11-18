import BaguetteDevice
import Foundation
import Mockable

/// Live capture from one `CameraSource` (a webcam, a still image, or a
/// looping video). `start` is conversational — the caller hands over an
/// `onFrame` callback that fires for every produced frame until `stop`
/// is called. The `CameraSession` pumps those frames into the
/// `FrameSink`; every source produces the same `CameraFrame`, so the
/// pipeline below this point is source-agnostic.
///
/// Each concrete handles the source cases it can produce and throws
/// `CameraCaptureError.unsupportedSource` for the rest — the session
/// only ever routes a source to the capture that owns it.
///
/// `start` is async to leave room for permission checks /
/// AVCaptureSession setup / asset loading on the production adapters,
/// but the conversation itself happens via the `onFrame` callback —
/// async here only covers the handshake.
@Mockable
protocol CameraCapture: AnyObject, Sendable {
    func start(
        source: CameraSource,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) async throws

    func stop() async
}

/// `LocalizedError` as well as `CustomStringConvertible` — see
/// `StillImageError` for why both spellings are needed.
enum CameraCaptureError: LocalizedError, Equatable, CustomStringConvertible {
    case unsupportedSource(String)

    var description: String {
        switch self {
        case .unsupportedSource(let kind):
            return "camera capture: this producer cannot source from '\(kind)'"
        }
    }

    var errorDescription: String? { description }
}
