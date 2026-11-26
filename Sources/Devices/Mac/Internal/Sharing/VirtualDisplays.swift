import Foundation
import Mockable

/// The displays this Mac can be given that no cable connects: each made once
/// to a shape and named, gone when removed — or when baguette exits. Its UUID
/// follows from its serial, so a display made again with the same serial is
/// the same device. A made display can't take another shape: a new shape is a
/// new display. Nil when the Mac won't make one. Decides nothing; the real one
/// is `CGVirtualDisplays`.
@Mockable
public protocol VirtualDisplays: Sendable {
    func create(named name: String, shape: SharedScreenShape, serial: UInt32) -> (any VirtualDisplay)?
}

/// One display made by `VirtualDisplays`: who it is to the Mac, and going away.
@Mockable
public protocol VirtualDisplay: AnyObject, Sendable {
    /// Its `CGDirectDisplayID`, new each time a display is made.
    var id: UInt32 { get }
    /// Its own UUID — its device id.
    var uuid: String { get }
    func remove()
}

/// How this Mac's displays are arranged: which is main — where the menu bar,
/// the Dock and new windows are — and making another main. Decides nothing;
/// the real one is `CGDisplayArrangement`.
@Mockable
public protocol DisplayArrangement: Sendable {
    var main: UInt32 { get }
    /// `freeingDock`: keep nothing beside the Dock's edge of `display` — a
    /// share made main, so an auto-hidden Dock can come up on it.
    func makeMain(_ display: UInt32, freeingDock: Bool) -> Bool
}
