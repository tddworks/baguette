import BaguetteDevice
import Foundation
import IOSurface
import Mockable

/// One picture ScreenCaptureKit hands over: its surface, when it has one, and
/// whether it is a complete new picture — an idle one repeats the last.
struct FeedPicture: @unchecked Sendable {
    let surface: IOSurface?
    let complete: Bool
}

/// Why a feed ended: the person stopped sharing from macOS itself, or it
/// failed (sleep, the display gone, an error) and may start again.
enum FeedEnd: Equatable, Sendable {
    case stoppedByUser
    case failed
}

/// ScreenCaptureKit's feed of one display's pictures: started, many pictures,
/// an end (sleep, the display gone, an error) — or stopped. Its pictures are
/// the size `sizing` gives for the display as ScreenCaptureKit sees it when
/// the feed starts — its points and pixels a point — never as this process
/// last read it: a display whose mode just changed (a shared one, made 1× and
/// then turned 2×) can read stale here. Starting throws
/// `ScreenRecordingRefused` when the permission isn't given. Decides nothing;
/// the real one is `ScreenCaptureKitFeed`.
@Mockable
protocol DisplayFeed: AnyObject, Sendable {
    func start(display: UInt32, sizing: @escaping @Sendable (Size, Double) -> Size,
               onPicture: @escaping @Sendable (FeedPicture) -> Void,
               onEnd: @escaping @Sendable (FeedEnd) -> Void) throws
    func stop()
}
