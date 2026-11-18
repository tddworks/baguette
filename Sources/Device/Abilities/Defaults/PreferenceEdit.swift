import Foundation

/// One change to an app's persisted preferences — store a value under a
/// key, or remove the key — with what happens to the running app spelled
/// out rather than implied.
///
/// A running app sees a change at once only for a key it watches
/// (`@AppStorage`); a key it read once at startup is invisible to it until
/// it re-reads, and its next save may write the old value back. A relaunch
/// quits the app first and launches it after, the one order that
/// guarantees it starts from the edited file. `Relaunch.whenNeeded` does
/// that only for a key the running app doesn't watch.
public struct PreferenceEdit: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case set(PreferenceValue)
        case remove
    }

    public let suite: PreferenceSuite
    public let key: String
    public let change: Change
    public let relaunch: Relaunch

    /// What applying did: whether anything changed, and whether the app was
    /// relaunched to see it (when not, it already sees it, or was left alone).
    public struct Applied: Equatable, Sendable {
        public let changed: Bool
        public let relaunched: Bool

        public init(changed: Bool, relaunched: Bool) {
            self.changed = changed
            self.relaunched = relaunched
        }
    }

    public init(suite: PreferenceSuite, key: String, change: Change, relaunch: Relaunch = .never) {
        self.suite = suite
        self.key = key
        self.change = change
        self.relaunch = relaunch
    }

    /// Apply the edit. `changed` is always true for a `set`, and for a
    /// `remove` only when the key was stored — removing an absent key is a
    /// no-op, so test setup can run it unconditionally.
    ///
    /// When storing fails the app stays quit: launching it would hide the
    /// failure behind a running app showing the old value.
    public func apply(on defaults: any Defaults, apps: any Apps) async throws -> Applied {
        let relaunching = relaunch == .whenNeeded
            ? relaunch.needed(for: [key], in: suite, lookups: try await defaults.lookups(of: suite.bundleID))
            : relaunch == .always
        if relaunching { try await apps.terminate(bundleID: suite.bundleID) }
        let changed: Bool
        switch change {
        case .set(let value):
            try await defaults.write(value, forKey: key, in: suite)
            changed = true
        case .remove:
            changed = try await defaults.read(suite).values[key] != nil
            if changed { try await defaults.delete(key: key, in: suite) }
        }
        if relaunching { try await apps.launch(bundleID: suite.bundleID) }
        return Applied(changed: changed, relaunched: relaunching)
    }
}
