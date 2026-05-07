import Foundation
import AppKit
import CoreGraphics

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
    init() {
        _ = Self.bootstrapWindowServer
    }

    /// One-shot WindowServer bootstrap. ScreenCaptureKit's first call
    /// asserts `CGS_REQUIRE_INIT` (`CGInitialization.c:44`) when the
    /// hosting process hasn't established a CGS connection — typical
    /// for plain Foundation-only Swift CLIs. We trigger the connection
    /// by calling `CGSessionCopyCurrentDictionary()` (ApplicationServices,
    /// no actor isolation, no AppKit drag-in) plus a probe of
    /// `CGMainDisplayID`. Either is enough on its own; calling both
    /// hedges against future SDK shuffles.
    ///
    /// Wrapped in a `static let` so the work runs at most once across
    /// the entire process even when several `RunningMacApps()`
    /// instances are constructed.
    private static let bootstrapWindowServer: Void = {
        _ = CGSessionCopyCurrentDictionary()
        _ = CGMainDisplayID()
    }()

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
