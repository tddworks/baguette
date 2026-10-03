import Foundation
import Mockable

/// Arms / disarms one dylib in a simulator's launchd-domain
/// `DYLD_INSERT_LIBRARIES`. The env var survives until the simulator
/// reboots, so the orchestrator re-arms on boot rather than every time a
/// feature starts.
///
/// Every call names the dylib, because the variable is **shared**: more
/// than one baguette feature injects (the virtual camera, motion, and
/// network conditioning), so arming must preserve whatever else is loaded
/// and disarming must remove only its own entry. `InjectedDylibs` models
/// that merge.
@Mockable
protocol SimulatorInjection: AnyObject, Sendable {
    func arm(dylibPath: String, on simulator: any Simulator) async throws
    func disarm(dylibPath: String, on simulator: any Simulator) async throws

    /// Whether this simulator would load this dylib into the next app it
    /// launches.
    ///
    /// An unset variable reports false; an unreadable environment throws.
    /// Callers use it to tell a condition that is *published* from
    /// one that is actually *applied* — a device can hold a state file it
    /// is no longer subject to, since a simulator reboot clears
    /// `DYLD_INSERT_LIBRARIES` and leaves the file behind.
    func armed(dylibPath: String, on simulator: any Simulator) async throws -> Bool
}
