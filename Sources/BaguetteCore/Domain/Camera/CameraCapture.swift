import Foundation
import Mockable

/// Live capture from one `CameraDevice`. `start` is conversational —
/// the caller hands over an `onFrame` callback that fires for every
/// captured frame until `stop` is called. The orchestrator pumps
/// those frames into the `FrameSink`.
///
/// `start` is async to leave room for permission checks /
/// AVCaptureSession setup on the production adapter, but the
/// conversation itself happens via the `onFrame` callback — async
/// here only covers the handshake.
@Mockable
protocol CameraCapture: AnyObject, Sendable {
    func start(
        device: CameraDevice,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) async throws

    func stop() async
}
