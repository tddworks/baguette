import Foundation

/// How a screen is read again once it has been observed. Only a foldable
/// can light another panel, and only a full observation (hinge sample
/// included) sees that. A single panel can't change identity, so its live
/// properties answer without the `simctl` round-trip.
enum ScreenRecheck {
    static func read(
        multiplePanels: Bool,
        observe: () throws -> AXScreen,
        live: () throws -> AXScreen
    ) throws -> AXScreen {
        multiplePanels ? try observe() : try live()
    }
}
