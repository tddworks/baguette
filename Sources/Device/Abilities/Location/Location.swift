import Foundation
import Mockable

/// A booted simulator's simulated-location surface. `set` pins the device
/// to a single `Coordinate`; `start` runs a moving route between
/// waypoints; `clear` drops the override back to the simulator's live
/// location.
///
/// Backed by `xcrun simctl location <udid> set | start | clear`. Like the
/// status-bar surface — and unlike the gesture path — this never touches
/// SimulatorHID; it's a one-shot subprocess. The production impl is
/// `SimctlLocation` (Infrastructure).
@Mockable
public protocol Location: Sendable {
    /// Pin the booted simulator to `coordinate`. Throws
    /// `LocationError.simctlFailed` when the spawn exits non-zero.
    func set(_ coordinate: Coordinate) async throws

    /// Run a moving-location route between the route's waypoints. Throws
    /// `LocationError.simctlFailed` when the spawn exits non-zero.
    func start(_ route: LocationRoute) async throws

    /// Clear any simulated location, restoring the device's live value.
    func clear() async throws
}

/// Failure modes the location surface surfaces. Maps to a CLI exit
/// message / HTTP error body.
public enum LocationError: Error, Equatable, CustomStringConvertible {
    /// `xcrun simctl location …` exited non-zero.
    case simctlFailed(status: Int32)

    public var description: String {
        switch self {
        case .simctlFailed(let status):
            return "xcrun simctl location exited \(status)"
        }
    }
}
