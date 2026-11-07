import Foundation

/// Launches an app and, when asked, answers with its first real screen, so
/// an agent's first call both opens the app and shows what's on it.
enum AppLaunch {
    static func perform(
        bundleID: String,
        relaunch: Bool,
        thenDescribeUI: Bool,
        apps: any Apps,
        accessibility: any Accessibility,
        affordances: AXAffordance.Style = .wire,
        timing: AXFirstScreen.Timing = AXFirstScreen.Timing()
    ) async -> String {
        do {
            if relaunch { try await apps.terminate(bundleID: bundleID) }
            guard thenDescribeUI else {
                try await apps.launch(bundleID: bundleID)
                return #"{"ok":true,"action":"launch"}"#
            }
            let before = try? accessibility.glance()
            try await apps.launch(bundleID: bundleID)
            let outcome = try AXFirstScreen.run(
                before: before,
                glance: { try? accessibility.glance() },
                wake: { try? accessibility.wake() },
                read: { try accessibility.describeAll() },
                timing: timing)
            let fields = outcome.tree.map { "," + $0.agentSummaryFields(affordances) } ?? ""
            return #"{"ok":true,"action":"launch","changed":\#(outcome.changed)\#(fields)}"#
        } catch {
            return #"{"ok":false,"action":"launch","error":"\#(GestureDispatcher.jsonEscape(String(describing: error)))"}"#
        }
    }
}
