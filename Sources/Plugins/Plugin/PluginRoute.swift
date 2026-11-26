import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// The plugin-facing surface: which capability each route demands.
///
/// This is a **closed** table, and that is the whole design. A path it
/// doesn't name maps to `nil`, and `nil` means *no manifest can ask for
/// this* — so a plugin token is refused there outright. When someone
/// adds a route to the server and forgets this file, the new route is
/// locked shut for plugins rather than silently open: the drift
/// direction is always toward less authority.
///
/// It's keyed on the path alone, not the method. Every capability here
/// covers one surface rather than one verb — `status-bar` is the
/// authority to read *and* override *and* clear the status bar, because
/// a plugin that can set it can already undo whatever was there. If a
/// route ever needs read and write split, that's two capabilities, not
/// a method check.
enum PluginRoute {

    /// The capability `path` demands, or `nil` when no plugin can reach
    /// it at all.
    static func capability(path: String) -> PluginCapability? {
        let segments = Self.segments(path)

        // The device list is the one plugin route with no udid in it.
        if segments == ["simulators.json"] { return .simulators }

        // Everything else is `/devices/<udid>/<leaf>`, or a simulator's
        // old `/simulators/<udid>/<leaf>` — one route, one capability. A
        // shorter path is a page (`/devices/<udid>`), not an API.
        guard segments.count >= 3, ["devices", "simulators"].contains(segments[0]) else { return nil }

        switch segments[2] {
        case "screenshot.jpg":    return .screenshot
        case "describe-ui.json":  return .describeUI
        case "input":             return .input
        case "status-bar":        return .statusBar
        case "interface",
             "interface.json":    return .interface
        case "location":          return .location
        case "apps":              return .apps
        case "media":             return .media
        // Launching what's already installed, not installing it — see
        // the note on `PluginCapability.openURL` for why that's a
        // different power from `apps`.
        case "openurl",
             "schemes.json":      return .openURL
        // `/files` is the browser's drag-and-drop endpoint and routes by
        // file extension, so the capability it demands would depend on
        // the bytes rather than the path. A content-dependent check is
        // exactly what this table exists to avoid, so plugins get the
        // two explicit routes above and this one stays shut to them.
        case "files":             return nil
        case "logs":              return .logs
        default:                  return nil
        }
    }

    /// Path components with the query string, empties and percent-escapes
    /// removed — so `/simulators/U/screenshot.jpg?scale=0.5` is the same
    /// route as `/simulators/U/screenshot.jpg`.
    private static func segments(_ path: String) -> [String] {
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return withoutQuery
            .split(separator: "/")
            .map { ($0.removingPercentEncoding ?? String($0)) }
    }
}
