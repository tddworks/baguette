import Foundation
import Mockable

/// A booted simulator's status-bar override surface. `override` pins one
/// or more indicators (time, carrier, network, signal bars, battery) to
/// fixed values; `clear` drops every override back to the simulator's
/// live readings.
///
/// Backed by `xcrun simctl status_bar <udid> override | clear`. Unlike
/// the gesture path, this never touches SimulatorHID — it's a one-shot
/// subprocess. The production impl is `SimctlStatusBar` (Infrastructure).
@Mockable
protocol StatusBar: Sendable {
    /// Apply `override` to the booted simulator. Throws
    /// `StatusBarError.emptyOverride` when nothing is set (simctl
    /// requires at least one flag) and `StatusBarError.simctlFailed`
    /// when the spawn exits non-zero.
    func override(_ override: StatusBarOverride) async throws

    /// Clear every status-bar override, restoring live values.
    func clear() async throws

    /// Read the simulator's current status-bar overrides (via
    /// `simctl status_bar … list`). Returns an empty override when
    /// nothing is pinned. Lets a UI hydrate its controls from the
    /// device instead of guessing.
    func read() async throws -> StatusBarOverride
}

/// Failure modes the status-bar surface surfaces. Each maps to a CLI
/// exit message / HTTP error body.
enum StatusBarError: Error, Equatable, CustomStringConvertible {
    /// `override` was called with no fields set — simctl needs at least one.
    case emptyOverride
    /// `xcrun simctl status_bar …` exited non-zero.
    case simctlFailed(status: Int32)

    var description: String {
        switch self {
        case .emptyOverride:
            return "no status-bar overrides specified (set at least one field)"
        case .simctlFailed(let status):
            return "xcrun simctl status_bar exited \(status)"
        }
    }
}
