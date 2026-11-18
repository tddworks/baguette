import Foundation
import Mockable

/// An app's persisted `UserDefaults` on a device — read a suite, store a
/// typed value under a key, remove a key. Named for what it is to the
/// developer ("the app's defaults"), like `Apps` / `StatusBar`.
///
/// Every operation goes through the simulator's own `cfprefsd` (`simctl
/// spawn <udid> defaults …`), never a host-side edit of the plist file,
/// so it can't race the daemon's cache. What it *can't* reach is an
/// already-running app's in-memory copy — `PreferenceEdit` makes the
/// quit / relaunch around an edit explicit.
///
/// `@Mockable` so the CLI command, serve routes and `PreferenceEdit` are
/// unit-tested without a booted simulator. The production impl is
/// `SimctlDefaults`.
@Mockable
public protocol Defaults: Sendable {
    /// Every persisted value in `suite`. A suite the app has never
    /// written reads as no values.
    func read(_ suite: PreferenceSuite) async throws -> Preferences

    /// Store `value` under `key`, its type intact. Unrelated keys are
    /// untouched.
    func write(_ value: PreferenceValue, forKey key: String, in suite: PreferenceSuite) async throws

    /// Remove `key`. Throws `DefaultsError.simctlFailed` when it isn't
    /// stored — `PreferenceEdit` reads first so callers never see that.
    func delete(key: String, in suite: PreferenceSuite) async throws

    /// The App Group identifiers the app has, sorted — the suites an
    /// editor can offer beside the app's standard defaults.
    func groups(of bundleID: String) async throws -> [String]

    /// The preferences the app, as it runs now, has looked up — its own
    /// code's reads and SwiftUI's `@AppStorage`, each typed. `nil` when no
    /// running app can answer: it isn't running, or it wasn't launched
    /// through baguette (only that launch carries
    /// `DefaultsLookups.dylib`, which listens).
    func lookups(of bundleID: String) async throws -> PreferenceLookups?
}

/// Why a defaults operation failed, each with the step the user can take.
/// The simctl exit codes behind these were measured on Xcode 27
/// (`docs/features/defaults/design.md`).
public enum DefaultsError: Error, Equatable, CustomStringConvertible {
    /// `get_app_container` exited 2 — nothing with that bundle id is installed.
    case appNotInstalled(bundleID: String)
    /// The app's App Group listing doesn't include the suite.
    case groupNotFound(group: String, bundleID: String)
    /// simctl exited 149 — the device is shut down.
    case deviceNotBooted
    /// `defaults export` printed something that isn't a preferences plist.
    case unreadableDomain
    /// Any other non-zero simctl exit.
    case simctlFailed(status: Int32)

    public var description: String {
        switch self {
        case .appNotInstalled(let bundleID):
            return "\(bundleID) is not installed on this simulator (check `xcrun simctl listapps`)"
        case .groupNotFound(let group, let bundleID):
            return "\(bundleID) has no App Group \(group) (check its com.apple.security.application-groups entitlement)"
        case .deviceNotBooted:
            return "the simulator is not booted (run `baguette boot`)"
        case .unreadableDomain:
            return "defaults export printed something that is not a preferences plist"
        case .simctlFailed(let status):
            return "xcrun simctl exited \(status)"
        }
    }
}
