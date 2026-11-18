import BaguetteDevice
import Foundation
import Mockable

/// Reads BGRA frames from a host video file in presentation order,
/// already fitted to the shared canvas. Conversational I/O collaborator
/// for `VideoFileCapture`: `start` opens the asset, `nextFrame` pulls
/// the next decoded frame (or `nil` at end of asset), `rewind` seeks
/// back to the first frame so the orchestrator can loop, and `stop`
/// tears the reader down. The concrete `AVVideoDecoder` wraps
/// `AVAssetReader`; tests inject `MockVideoDecoder` to drive the loop
/// deterministically without a real file.
@Mockable
protocol VideoDecoder: AnyObject, Sendable {
    /// Open `path` and configure decoding so every frame arrives fitted
    /// within `maxDimension × maxDimension`. Async because modern
    /// AVFoundation loads track metadata asynchronously.
    func start(path: String, maxDimension: Int) async throws

    /// The next frame in presentation order, or `nil` once the asset is
    /// exhausted (the caller then `rewind`s to loop).
    func nextFrame() throws -> DecodedVideoFrame?

    /// Seek back to the first frame so playback can repeat.
    func rewind() async throws

    func stop()
}
