import Foundation
import AppKit

/// Production `MacApps` — backed by `NSWorkspace.runningApplications`.
///
/// Pure projection: enumerate `NSWorkspace.shared.runningApplications`,
/// project each entry into `RunningAppSnapshot`, hand to
/// `MacApp.from(snapshot:host:)`. The factory in Domain handles
/// the `nil`-bundle-ID filter; the adapter just adapts.
///
/// Per-app capability handles (`screen` / `accessibility` / `input`)
/// return fresh values so the caller owns lifecycle. The underlying
/// frameworks (ScreenCaptureKit, AXUIElement, CGEvent) carry no
/// per-aggregate shared state worth caching.
final class RunningMacApps: MacApps, @unchecked Sendable {
    init() {}

    var all: [MacApp] {
        NSWorkspace.shared.runningApplications.compactMap { running -> MacApp? in
            let snap = RunningAppSnapshot(
                bundleID: running.bundleIdentifier ?? "",
                pid: running.processIdentifier,
                name: running.localizedName ?? running.bundleIdentifier ?? "",
                isActive: running.isActive
            )
            return MacApp.from(snapshot: snap, host: self)
        }
    }

    func find(bundleID: String) -> MacApp? {
        all.first { $0.bundleID == bundleID }
    }

    func screen(for app: MacApp) -> any Screen {
        ScreenCaptureKitScreen(pid: app.pid)
    }

    func accessibility(for app: MacApp) -> any Accessibility {
        AXUIElementAccessibility(pid: app.pid)
    }

    func input(for app: MacApp) -> any Input {
        CGEventInput(pid: app.pid)
    }
}
