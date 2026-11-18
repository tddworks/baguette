import BaguetteDevice
import Foundation

/// A saved set of preferences written back in one go — what makes an
/// export a repeatable test setup. Like `PreferenceEdit`, the running
/// app's lifecycle is explicit: a relaunch quits it once before the first
/// value and launches it once after the last, so it starts from the whole
/// set rather than restarting per key. `Relaunch.whenNeeded` relaunches
/// when any key in the set is one the running app doesn't watch.
public struct PreferenceImport: Equatable, Sendable {
    public let suite: PreferenceSuite
    public let preferences: Preferences
    public let relaunch: Relaunch

    /// How many values were written, and whether the app was relaunched.
    public struct Applied: Equatable, Sendable {
        public let written: Int
        public let relaunched: Bool
    }

    public init(suite: PreferenceSuite, preferences: Preferences, relaunch: Relaunch = .never) {
        self.suite = suite
        self.preferences = preferences
        self.relaunch = relaunch
    }

    /// Write every value, in key order. Keys not in the import are left
    /// alone. Stops at the first failure and leaves the app quit, as
    /// `PreferenceEdit` does.
    func apply(on defaults: any Defaults, apps: any Apps) async throws -> Applied {
        let keys = preferences.values.keys.sorted()
        let relaunching = relaunch == .whenNeeded
            ? relaunch.needed(for: keys, in: suite, lookups: try await defaults.lookups(of: suite.bundleID))
            : relaunch == .always
        if relaunching { try await apps.terminate(bundleID: suite.bundleID) }
        for key in keys {
            try await defaults.write(preferences.values[key]!, forKey: key, in: suite)
        }
        if relaunching { try await apps.launch(bundleID: suite.bundleID) }
        return Applied(written: keys.count, relaunched: relaunching)
    }
}
