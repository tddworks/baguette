import Foundation
import Mockable

/// One display plane on a simulator — the aggregate root for that
/// surface's capture and HID. Callers obtain `Screen` / `Input` only
/// here so a CarPlay framebuffer cannot pair with the phone digitizer.
///
/// Invariant: `screen()` and `input()` share one resolved
/// `DisplayBinding` (or resolve lazily to the same live binding).
@Mockable
protocol Display: Sendable {
    var kind: DisplayKind { get }

    /// Resolve (or refresh) the live binding: pick the IOSurface port
    /// for this kind, read connectedScreenId + size. Throws if the
    /// plane is absent (CarPlay not connected yet).
    func resolve() throws -> DisplayBinding

    /// Fresh Screen subscribed to this display's framebuffer port.
    func screen() -> any Screen

    /// Fresh Input whose digitizer target is derived from
    /// `binding.connectedScreenId` (never a hard-coded CarPlay constant).
    func input() -> any Input

    /// The screen an observation describes right now: native panel
    /// points, the observed interface orientation and the connected
    /// screen's identity. An unknown panel selection or geometry fails
    /// closed rather than guessing a phone-sized portrait panel.
    func observedScreen() throws -> AXScreen
}

extension Display {
    func observedScreen() throws -> AXScreen { throw ObservedScreenError.unavailable }
}
