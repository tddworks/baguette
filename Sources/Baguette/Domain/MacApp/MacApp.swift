import Foundation

/// One running macOS app on the host. Identity (`bundleID`, `pid`,
/// `name`), an `isActive` flag (true iff this is the frontmost app), and
/// the same capability verbs as `Simulator` — `screen`, `accessibility`,
/// `input` — so a single agent can drive both iOS simulators and native
/// macOS apps through identical surface area.
///
/// Carries `host: any MacApps` so `app.screen()` reads as a verb on the
/// value, with the actual work done by the injected aggregate. Equality
/// and the JSON projection ignore the host, so two apps with the same
/// identity compare equal even when produced by different aggregates
/// (e.g. mock vs live).
struct MacApp: Sendable {
    let bundleID: String
    let pid: pid_t
    let name: String
    let isActive: Bool
    let host: any MacApps

    init(
        bundleID: String,
        pid: pid_t,
        name: String,
        isActive: Bool,
        host: any MacApps
    ) {
        self.bundleID = bundleID
        self.pid = pid
        self.name = name
        self.isActive = isActive
        self.host = host
    }

    /// Subscribe to this app's frame stream.
    func screen() -> any Screen {
        host.screen(for: self)
    }

    /// Read the app's on-screen UI tree (labels, frames, traits).
    func accessibility() -> any Accessibility {
        host.accessibility(for: self)
    }

    /// Dispatch gestures to this app.
    func input() -> any Input {
        host.input(for: self)
    }

    /// Compact JSON for the `mac list` subcommand's stdout and the
    /// `serve` `/mac.json` endpoint. Field order is part of the
    /// contract — callers grep for it.
    var json: String {
        let escapedName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"bundleID\":\"\(bundleID)\",\"pid\":\(pid),\"name\":\"\(escapedName)\",\"active\":\(isActive)}"
    }
}

extension MacApp: Equatable {
    static func == (lhs: MacApp, rhs: MacApp) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.pid == rhs.pid
            && lhs.name == rhs.name
            && lhs.isActive == rhs.isActive
    }
}

/// Lightweight description of a running app, decoupled from
/// `NSRunningApplication`. The Infrastructure adapter projects each
/// real `NSRunningApplication` into one of these so the
/// `MacApp.from(snapshot:host:)` factory can be unit-tested without
/// AppKit.
struct RunningAppSnapshot: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
    let name: String
    let isActive: Bool
}

extension MacApp {
    /// Build a `MacApp` from a snapshot of the live `NSRunningApplication`
    /// state plus the aggregate that owns it. The factory is pure and
    /// unit-tested; the adapter only has to read fields off the
    /// `NSRunningApplication` and call this.
    ///
    /// Returns `nil` when the snapshot has no `bundleID` — agent-style
    /// callers can't address an app without one, so it's not worth
    /// surfacing those at the domain boundary.
    static func from(snapshot: RunningAppSnapshot, host: any MacApps) -> MacApp? {
        guard !snapshot.bundleID.isEmpty else { return nil }
        return MacApp(
            bundleID: snapshot.bundleID,
            pid: snapshot.pid,
            name: snapshot.name,
            isActive: snapshot.isActive,
            host: host
        )
    }
}
