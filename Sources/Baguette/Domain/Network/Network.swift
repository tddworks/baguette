import Foundation
import Mockable

/// A booted simulator's network conditioning. `apply` states how degraded
/// the network is and makes apps subject to it; `clear` stops conditioning
/// and stops future app launches picking it up.
///
/// Like `Motion` and unlike `Location`, there is no `simctl` verb behind
/// this. The host's own tooling for it — Network Link Conditioner, and the
/// `dnctl` / `pfctl` dummynet rules underneath it — is **system-wide**:
/// simulator apps use the host's network stack as the host user, so there
/// is no interface or process to scope a rule to. Conditioning one
/// simulator means degrading the whole Mac, every other simulator included.
/// Injecting into the app under test is the only way to scope it, so the
/// production impl is `SharedFileNetwork` (Infrastructure); see
/// `docs/features/network/README.md`.
@Mockable
protocol Network: AnyObject, Sendable {
    /// State how degraded the network is, and arm the dylib so apps
    /// launched from now on are subject to it.
    func apply(_ condition: NetworkCondition, on simulator: any Simulator) async throws

    /// Stop conditioning. Apps launched afterwards load nothing; apps
    /// **already running** still have the dylib loaded, so this also
    /// publishes an unconditioned state for them to read — otherwise they
    /// would stay throttled for as long as they keep running.
    func clear(on simulator: any Simulator) async throws

    /// What this simulator's apps are actually subject to, or `nil` when
    /// nothing is. Throws when the injection state cannot be determined.
    ///
    /// This exists for one reason: a throttle nobody remembers arming does
    /// not announce itself, it just makes the app feel slow — so "is
    /// anything on?" has to be answerable cheaply, by the CLI's `status`
    /// and by the browser card's badge.
    ///
    /// *This* simulator, not the host. The condition is published to one
    /// shared file, so a second simulator can see the same bytes without
    /// having the dylib armed; reporting a condition there would be a false
    /// alarm, and a badge that cries wolf stops being read.
    func current(on simulator: any Simulator) async throws -> NetworkCondition?
}

/// Failure modes the network surface surfaces. Maps to a CLI exit message /
/// HTTP error body.
enum NetworkError: Error, Equatable, CustomStringConvertible {
    /// This build doesn't carry `VirtualNetwork.dylib`, so there's nothing
    /// to inject and nothing would read a published condition.
    case dylibMissing

    var description: String {
        switch self {
        case .dylibMissing:
            return "VirtualNetwork.dylib is not bundled in this build"
        }
    }
}
