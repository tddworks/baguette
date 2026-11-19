import Foundation
import Mockable

/// The guest-side surface baguette's input lands on — the legacy Indigo
/// HID services backboardd's `SimulatorHID` hosts, which `IndigoHIDInput`
/// addresses through `SimDeviceLegacyHIDClient`.
///
/// Under Xcode 27 that surface can be **shadowed**: Device Hub attaches
/// its own HID daemon to every booted device and backboardd tears the
/// legacy services down in its favour, after which they never come back
/// (`DeviceHubAttachment` has the full story). Input keeps reporting
/// success into the void. This abstraction asks the one question that
/// matters and performs the one repair that works.
@Mockable
public protocol InputSurface: AnyObject, Sendable {
    /// Whether Device Hub has attached to this simulator during the
    /// current boot. Not throwing: a device that is shut down, or a host
    /// without Device Hub at all, simply isn't shadowed.
    func shadowed() async -> Bool

    /// Wait until the surface exists — SpringBoard is running in the
    /// guest. `Simulator.boot()` returns as soon as the device *state*
    /// flips, seconds before backboardd, Device Hub's daemon, or
    /// SpringBoard are up; asking `shadowed` before then reads a state
    /// nobody has set yet. Throws if the guest never gets there.
    func ready() async throws

    /// Take the surface back: convince backboardd Device Hub is absent
    /// and restart it, so its `SimulatorHID` re-initialises with every
    /// legacy service live — Device Hub's own services re-register
    /// alongside, unaffected. SpringBoard restarts with backboardd, so
    /// **running apps are killed**; returns once SpringBoard is back.
    func reclaim() async throws
}

public extension InputSurface {
    /// Reclaim the surface only if Device Hub has shadowed it. This is
    /// what `baguette boot` runs once the device is up (nothing is
    /// running yet, so the restart costs nothing) and what `baguette
    /// heal` runs on demand.
    func heal() async throws -> HealOutcome {
        guard await shadowed() else { return .unshadowed }
        try await reclaim()
        return .reclaimed
    }

    /// `heal`, but first let the freshly booted guest finish coming up —
    /// otherwise the shadow check runs before Device Hub has attached and
    /// answers "fine" about a surface that is about to be taken.
    func healAfterBoot() async throws -> HealOutcome {
        try await ready()
        return try await heal()
    }
}

public enum HealOutcome: Equatable, Sendable {
    /// Device Hub never attached; there was nothing to do.
    case unshadowed
    /// backboardd was restarted and the legacy services are live again.
    case reclaimed

    public var summary: String {
        switch self {
        case .unshadowed:
            return "Input surface is not shadowed by Device Hub — nothing to heal"
        case .reclaimed:
            return "Input surface reclaimed from Device Hub (SpringBoard restarted)"
        }
    }
}

public enum InputSurfaceError: Error, Equatable, CustomStringConvertible {
    case simctlFailed(status: Int32)
    /// backboardd was restarted but SpringBoard never came back — the
    /// device is in an unknown state and a reboot is the honest advice.
    case springBoardMissing

    public var description: String {
        switch self {
        case .simctlFailed(let status):
            return "xcrun simctl exited \(status) while reclaiming the input surface"
        case .springBoardMissing:
            return "SpringBoard did not come back after restarting backboardd — reboot the simulator"
        }
    }
}
