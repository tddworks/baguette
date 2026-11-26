import BaguetteDevice
import Foundation

extension MacDisplays {
    /// This Mac's own displays, watched through ScreenCaptureKit and driven
    /// through the window server. Integration-only: the real parts, put together.
    public static func onThisMac(madePixels: @escaping @Sendable (String) -> Size? = { _ in nil }) -> MacDisplays {
        MacDisplays(displays: { HostDisplayList.all() }, feed: { ScreenCaptureKitFeed() },
                    events: WindowServerEvents(server: CGEventWindowServer()),
                    madePixels: madePixels, bounds: HostDisplayList.bounds(of:))
    }
}
