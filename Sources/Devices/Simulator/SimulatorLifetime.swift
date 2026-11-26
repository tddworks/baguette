import BaguetteDevice
import Foundation

/// Simulator.app's device lifetime policy — whether closing a
/// simulator's window, or quitting the app, leaves the device booted
/// or shuts it down.
///
/// Apple exposes exactly two preferences for this, grouped under
/// "Simulator lifetime" in `Simulator.app/Contents/Resources/
/// Settings.bundle/Root.plist`:
///
///   DetachOnWindowClose — "When closing a simulator's window leave it running"
///   DetachOnAppQuit     — "When quitting leave simulators running"
///
/// Both ship as `false`. That default is why a device baguette booted
/// headlessly dies the moment anything opens it in Simulator.app and
/// the window is later closed — a common way to lose a device is a
/// toolchain (Expo, `xcrun simctl` wrappers, Xcode itself) opening
/// Simulator.app on your behalf.
///
/// Per AGENTS.md's one-shot-fetch split, everything downstream of the
/// fetched plist lives here as a pure factory; the irreducible
/// `CFPreferences` read/write pair is the only Infrastructure code.
public struct SimulatorLifetime: Equatable, Sendable {
    /// Closing a simulator's window detaches from the device instead
    /// of shutting it down.
    public var detachOnWindowClose: Bool
    /// Quitting Simulator.app leaves booted devices running.
    public var detachOnAppQuit: Bool

    /// Simulator.app's own preference key for the window-close route.
    /// These spellings are the contract with Apple — a typo writes a
    /// key nothing reads.
    static let windowCloseKey = "DetachOnWindowClose"
    /// Simulator.app's own preference key for the app-quit route.
    static let appQuitKey = "DetachOnAppQuit"

    /// What Simulator.app does out of the box: both routes shut the
    /// device down.
    public static let appleDefault = SimulatorLifetime(
        detachOnWindowClose: false,
        detachOnAppQuit: false
    )

    /// Both routes detach, so a booted device outlives Simulator.app.
    public static let detached = SimulatorLifetime(
        detachOnWindowClose: true,
        detachOnAppQuit: true
    )

    /// A device only outlives Simulator.app when *both* routes detach —
    /// closing the window and quitting the app are independent ways to
    /// lose a booted simulator, so opting out of one still loses it by
    /// the other.
    public var survivesSimulatorApp: Bool { detachOnWindowClose && detachOnAppQuit }

    /// Read the policy out of Simulator.app's preferences.
    ///
    /// An absent key means shutdown, not "unset" — a machine that has
    /// never touched these preferences has no entry at all, and
    /// reporting that as anything other than shutdown would misdescribe
    /// what Simulator.app is about to do.
    static func from(plist: [String: Any]) -> SimulatorLifetime {
        SimulatorLifetime(
            detachOnWindowClose: flag(plist[windowCloseKey]),
            detachOnAppQuit: flag(plist[appQuitKey])
        )
    }

    /// The keys to write back. Both are always present: reverting must
    /// write `false` rather than remove the keys, so a user who opted
    /// in can see the revert land in `defaults read`.
    var plistPatch: [String: Bool] {
        [
            Self.windowCloseKey: detachOnWindowClose,
            Self.appQuitKey: detachOnAppQuit,
        ]
    }

    /// What moving the policy to `desired` amounts to.
    public enum Change: Equatable, Sendable {
        /// The machine is already at the requested policy — nothing
        /// was written.
        case unchanged
        /// The caller should write the requested policy.
        /// `restartSimulatorApp` is true when Simulator.app was running,
        /// so the write may not stick without a restart.
        case applied(restartSimulatorApp: Bool)
    }

    /// Decide what asking for `desired` should do.
    ///
    /// A running Simulator.app doesn't block the write, but it does
    /// mean the change isn't reliably live: the app can hold a cached
    /// copy of these keys and flush it back over the write when it
    /// quits. Callers surface that as "restart Simulator.app" rather
    /// than refusing — a device is often booted through Simulator.app
    /// in the first place, so refusing would block the common case.
    public func change(to desired: SimulatorLifetime, simulatorAppRunning: Bool) -> Change {
        guard self != desired else { return .unchanged }
        return .applied(restartSimulatorApp: simulatorAppRunning)
    }

    /// A one-line warning for commands that hold a device open (`serve`,
    /// `boot`), or nil when the policy already keeps devices alive.
    ///
    /// Only the routes that will actually shut a device down are named.
    /// The two keys are independent checkboxes in Simulator → Settings,
    /// so a half-detached policy is reachable, and claiming a route
    /// shuts devices down when it doesn't would misdescribe what
    /// Simulator.app is going to do — the one thing this message exists
    /// to get right.
    ///
    /// It also names the command that fixes it: an advisory that only
    /// describes the problem is noise.
    public var advisory: String? {
        guard !survivesSimulatorApp else { return nil }
        // The guard leaves at least one route live, so this is never
        // empty.
        var routes: [String] = []
        if !detachOnWindowClose { routes.append("their window is closed") }
        if !detachOnAppQuit { routes.append("Simulator.app quits") }
        return """
            Booted devices will be shut down when \(routes.joined(separator: " or ")) \
            — run `baguette lifetime --detach` to leave them running.
            """
    }

    /// Parse one preference value the way `-[NSUserDefaults boolForKey:]`
    /// would.
    ///
    /// `defaults write … -bool YES` stores a CFBoolean that arrives as
    /// `NSNumber`, but `defaults write … YES` (no `-bool`) stores the
    /// *string* `"YES"` — and NSUserDefaults still reads that as true.
    /// Matching those semantics keeps the reported policy equal to the
    /// one Simulator.app will act on. Anything else is unreadable, and
    /// unreadable falls back to shutdown rather than claiming safety.
    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String: return (string as NSString).boolValue
        default: return false
        }
    }
}
