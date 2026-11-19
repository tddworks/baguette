import Foundation
import IOSurface
import Mockable

/// A reel of film: open it against a file, append frames onto it, close
/// it. One recording, one reel.
///
/// This is the conversational boundary `baguette record` talks to the
/// outside world across — `AVAssetWriter` wants a back-and-forth (start
/// a session, feed it a buffer with a presentation time, finish and
/// flush), which is exactly the shape AGENTS.md's second adapter pattern
/// calls for: one small `@Mockable` collaborator named as a domain noun,
/// with the orchestration (`ScreenRecorder`) depending on `any Reel` and
/// unit-tested through `MockReel`. The concrete `AVAssetWriterReel` is a
/// thin wrapper and stays integration-only.
///
/// The reel receives the raw simulator surface plus the `CapturePlacement`
/// it was opened with, and does the letterbox/crop compositing itself —
/// that is a GPU blit, not a decision. Every *decision* (how big, where
/// the frame lands, which frames make the cut) is already settled in the
/// domain before a reel ever sees a pixel.
@Mockable
public protocol Reel: AnyObject, Sendable {
    /// Begin writing to `url`. `placement` is the canvas size plus where
    /// each frame lands inside it; `plan` carries the frame rate,
    /// bitrate, background, and container. Throws if the writer refuses
    /// the session.
    func open(to url: URL, placement: CapturePlacement, plan: RecordingPlan) throws

    /// Composite one simulator frame onto the canvas at `seconds` past
    /// the start of the recording. Never blocks: a frame the encoder
    /// isn't ready for is dropped and reported as `false`, so the
    /// recorder's summary counts what was written rather than what was
    /// offered.
    func append(frame: IOSurface, at seconds: Double) -> Bool

    /// Flush and close the file. Throws if the writer failed mid-write.
    func close() async throws

    /// Abandon the take: stop writing and leave nothing at `url`. Used
    /// when the recording turned out to have no frames in it — a file
    /// that was opened and never written to plays nowhere, and leaving
    /// that stub at the path the user named is worse than leaving the
    /// path untouched. A reel that was never opened does nothing.
    func discard()
}
