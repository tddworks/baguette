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

/// ScreenCaptureKit's feed of one display's pictures, at a size: started,
/// many pictures, an end (sleep, the display gone, an error) — or stopped.
/// Starting throws `ScreenRecordingRefused` when the permission isn't given.
/// Decides nothing; the real one is `ScreenCaptureKitFeed`.
@Mockable
protocol DisplayFeed: AnyObject, Sendable {
    func start(display: UInt32, size: Size,
               onPicture: @escaping @Sendable (FeedPicture) -> Void,
               onEnd: @escaping @Sendable () -> Void) throws
    func stop()
}
