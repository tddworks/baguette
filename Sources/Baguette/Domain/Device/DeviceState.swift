import Foundation

/// Whether a device can be driven right now — the same four answers for
/// every device family. Each family reads its own states onto these
/// (`SimulatorState.deviceState`; `devicectl`'s "available (paired)";
/// adb's `device` / `offline` / `unauthorized`).
enum DeviceState: Equatable, Sendable {
    /// Not running: a simulator shut down, an emulator's AVD not started.
    case off
    /// On its way to ready: being created or booting.
    case starting
    /// On, reachable and taking gestures.
    case ready
    /// Present but not drivable, and why: locked, unpaired, no developer
    /// disk mounted, adb `unauthorized`.
    case unavailable(reason: String)
}

extension DeviceState {
    /// Only a ready device accepts gestures and streams.
    var canAcceptInput: Bool { self == .ready }
}

extension SimulatorState {
    /// A simulator's state in the words every device family shares.
    var deviceState: DeviceState {
        switch self {
        case .booted:                   return .ready
        case .creating, .booting:       return .starting
        case .shutdown, .shuttingDown:  return .off
        }
    }
}
