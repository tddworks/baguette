import Foundation
import Mockable

/// The host's collection of running macOS apps. Lists what's running,
/// finds by bundle ID, and produces `Screen` / `Accessibility` / `Input`
/// handles for each app. Mirrors `Simulators` exactly so call sites can
/// share orchestration code by protocol.
///
/// `@Mockable` so domain tests can drive the aggregate's contract without
/// `NSWorkspace` / `ScreenCaptureKit`. Class-bound (`AnyObject`) because
/// each `MacApp` value carries `host: any MacApps` as a reference.
@Mockable
protocol MacApps: AnyObject, Sendable {
    /// Every app currently running, in `NSWorkspace` order. Includes
    /// background-only apps (`activationPolicy != .regular`); callers
    /// that only want UI apps filter on `name` / `bundleID`.
    var all: [MacApp] { get }

    /// Look up a running app by bundle identifier. Returns `nil` when
    /// no running app matches — start the app via `NSWorkspace` first.
    func find(bundleID: String) -> MacApp?

    /// Produce a `Screen` for the app. Each call returns a fresh
    /// pipeline; a per-app SCStream is cheap to spin up.
    func screen(for app: MacApp) -> any Screen

    /// Produce an `Accessibility` snapshot port for the app. Each call
    /// returns a fresh handle; the underlying `AXUIElementCreateApplication`
    /// is a one-shot fetch with no shared state to manage.
    func accessibility(for app: MacApp) -> any Accessibility

    /// Produce an `Input` for the app. Posting `CGEvent`s is
    /// stateless, so each handle is a thin per-app wrapper.
    func input(for app: MacApp) -> any Input
}

extension MacApps {
    /// Frontmost app (typically zero or one). Surfaced in the serve UI
    /// so the user can see which app the keyboard is going to. Filtering
    /// here keeps the route handler dumb.
    var active: [MacApp] {
        all.filter(\.isActive)
    }

    /// Background apps (everything that isn't frontmost). Sometimes
    /// useful for picking a target other than the active one.
    var inactive: [MacApp] {
        all.filter { !$0.isActive }
    }

    /// JSON projection consumed by the `/mac.json` endpoint. Sorted
    /// keys keep diffs and snapshot tests readable; the section split
    /// mirrors the page's ACTIVE / OTHERS layout.
    var listJSON: String {
        let dict: [String: Any] = [
            "active":   active.map(\.dictionary),
            "inactive": inactive.map(\.dictionary),
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

private extension MacApp {
    var dictionary: [String: Any] {
        [
            "bundleID": bundleID,
            "pid":      Int(pid),
            "name":     name,
            "active":   isActive,
        ]
    }
}
