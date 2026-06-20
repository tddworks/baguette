import Foundation
import Mockable

/// Raw BGRA frame as delivered by the platform capture session.
/// `baseAddress` is only valid for the duration of the `onFrame`
/// callback — callers must finish reading before they return.
struct RawBGRAFrame: @unchecked Sendable {
    let baseAddress: UnsafeRawPointer
    let width: UInt32
    let height: UInt32
    let bytesPerRow: Int
    let timestampMs: UInt32
}

/// Conversational I/O collaborator: starts a platform capture
/// session against `deviceUniqueID` and fires `onFrame` for every
/// captured BGRA frame until `stop()` lands. The orchestrator
/// (`AVCameraCapture`) layers BGRA-packing + sequence counting on
/// top of this; tests inject `MockVideoCapture` to drive the state
/// machine deterministically.
@Mockable
protocol VideoCapture: AnyObject, Sendable {
    func start(
        deviceUniqueID: String,
        onFrame: @escaping @Sendable (RawBGRAFrame) -> Void
    ) async throws

    func stop() async
}
