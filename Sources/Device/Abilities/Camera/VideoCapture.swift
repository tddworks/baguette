import Foundation
import Mockable

/// Raw BGRA frame as delivered by the platform capture session.
/// `baseAddress` is only valid for the duration of the `onFrame`
/// callback — callers must finish reading before they return.
public struct RawBGRAFrame: @unchecked Sendable {
    public let baseAddress: UnsafeRawPointer
    public let width: UInt32
    public let height: UInt32
    public let bytesPerRow: Int
    public let timestampMs: UInt32

    public init(baseAddress: UnsafeRawPointer, width: UInt32, height: UInt32, bytesPerRow: Int, timestampMs: UInt32) {
        self.baseAddress = baseAddress
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.timestampMs = timestampMs
    }
}

/// Conversational I/O collaborator: starts a platform capture
/// session against `deviceUniqueID` and fires `onFrame` for every
/// captured BGRA frame until `stop()` lands. The orchestrator
/// (`AVCameraCapture`) layers BGRA-packing + sequence counting on
/// top of this; tests inject `MockVideoCapture` to drive the state
/// machine deterministically.
@Mockable
public protocol VideoCapture: AnyObject, Sendable {
    func start(
        deviceUniqueID: String,
        onFrame: @escaping @Sendable (RawBGRAFrame) -> Void
    ) async throws

    func stop() async
}
