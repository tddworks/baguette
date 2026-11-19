import Foundation

/// Whether a device can be driven right now — the same four answers for
/// every device family. Each family reads its own states onto these
/// (`SimulatorState.deviceState`; `devicectl`'s "available (paired)";
/// adb's `device` / `offline` / `unauthorized`).
public enum DeviceState: Equatable, Sendable {
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

public extension DeviceState {
    /// Only a ready device accepts gestures and streams.
    var canAcceptInput: Bool { self == .ready }
}
