import Foundation
import Mockable

/// A device's pointer, moved with no button down — what a Mac's hover
/// effects, tooltips and auto-hidden Dock follow. Only a device with a
/// pointer of its own (a Mac display) registers it; a touch screen has none.
@Mockable
public protocol Pointer: Sendable {
    /// Move the pointer to `point`, in device points beside the screen's `size`.
    func move(to point: Point, size: Size) -> Bool
}

public extension Ability where Role == any Pointer {
    static var pointer: Self { .init(name: "pointer", needsReady: true) }
}
