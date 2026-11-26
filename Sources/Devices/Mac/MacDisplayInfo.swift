import BaguetteDevice
import Foundation

/// One display attached to this Mac, as CoreGraphics lists it — no Screen
/// Recording asked. `id` is this boot's `CGDirectDisplayID`; `uuid` is the
/// display's own, the same across reboots, and names it as a device.
public struct MacDisplayInfo: Equatable, Sendable {
    let id: UInt32
    let uuid: String
    let name: String
    let isMain: Bool
    /// Where it sits on the desktop, in global points (the main display's
    /// top-left at 0,0, y down) — where its events land.
    let bounds: Rect
}

/// Screen Recording isn't allowed for the app that launched baguette.
struct ScreenRecordingRefused: Error, Equatable, CustomStringConvertible {
    var description: String {
        "Screen Recording is not allowed for the app that runs baguette — "
            + "allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then run it again"
    }
}
