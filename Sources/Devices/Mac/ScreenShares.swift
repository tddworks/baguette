import Foundation
import Mockable

/// How a shared display sits among the Mac's others.
public enum ShareUse: String, Sendable {
    /// The main display while shared: menu bar, Dock and new windows there.
    case main
    /// One more display beside the Mac's own; the main display stays.
    case extra

    /// The use a viewer asks for by name; extra when they name none.
    init?(wire: String?) {
        guard let wire else { self = .extra; return }
        self.init(rawValue: wire)
    }
}

/// This Mac shared to its viewers' devices, each through a display of the
/// viewer's shape, known by the display's UUID — its device id. Started,
/// reshaped as the viewer turns, ended when it leaves. The real one is
/// `VirtualDisplayShares`.
@Mockable
public protocol ScreenShares: Sendable {
    /// Share the Mac to `viewer` through a new display of `shape`; its id, or
    /// nil when the Mac won't make the display.
    func start(viewer: String, shape: SharedScreenShape, use: ShareUse) -> String?
    func isSharing(_ id: String) -> Bool
    /// The share's display made again in `shape`; false when there's no such share.
    func reshape(_ id: String, to shape: SharedScreenShape) -> Bool
    func end(_ id: String)
}
