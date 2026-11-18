import BaguetteDevice
import Foundation

/// Where the frames streamed into the simulator's camera come from.
/// The webcam path carries the `AVCaptureDevice.uniqueID`; the file
/// paths point at a host image / video the browser uploaded and the
/// server staged. The downstream pipeline (sink → shared buffer →
/// dylib) is identical for all three — only the frame *producer*
/// differs, so this is the one value that selects it.
enum CameraSource: Equatable, Sendable {
    case device(uid: String)
    case image(path: String)
    case video(path: String)

    /// The token reported to the browser in `camera_state.source` and
    /// sent back in `camera_start.source`.
    var wireKind: String {
        switch self {
        case .device: return "webcam"
        case .image:  return "image"
        case .video:  return "video"
        }
    }
}
