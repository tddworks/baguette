import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import Mockable

/// The plugins installed on this machine — a DDD collection over the
/// `Plugin` aggregate, named as the plural of the aggregate alongside
/// `Simulators` / `Chromes` / `Cameras` / `Apps`.
///
/// `all()` throws only when the roots themselves are unreadable. A
/// single malformed `baguette-plugin.json` is *not* an error: one bad
/// plugin must not blank the whole toolbar, so implementations skip
/// and warn. See `FileSystemPlugins`.
///
/// `@Mockable` so the serve routes and the CLI can be unit-tested with
/// no plugins installed on the machine running the suite.
@Mockable
protocol Plugins: Sendable {
    func all() throws -> [Plugin]
}

extension Plugins {

    /// Find an installed plugin by its manifest name.
    func plugin(named name: String) throws -> Plugin? {
        try all().first { $0.id == name }
    }

    /// Resolve a namespaced command id (`a11y:audit`) to the plugin
    /// that owns it and the command itself.
    func resolve(qualifiedCommand id: String) throws -> (Plugin, PluginCommand)? {
        for plugin in try all() {
            if let command = plugin.command(qualified: id) { return (plugin, command) }
        }
        return nil
    }

    /// JSON projection consumed by `GET /plugins.json`.
    ///
    /// Command ids and panel body sources arrive pre-qualified so the
    /// browser can POST straight back without knowing the namespacing
    /// rule. The `run` argv is deliberately withheld: the page never
    /// invokes an executable itself, and publishing local filesystem
    /// paths into the DOM serves nobody.
    ///
    /// Sorted keys keep diffs and snapshot tests readable, matching
    /// `Simulators.listJSON`.
    var listJSON: String {
        get throws {
            let dict: [String: Any] = ["plugins": try all().map(\.dictionary)]
            let data = try JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys]
            )
            return String(decoding: data, as: UTF8.self)
        }
    }
}

private extension Plugin {
    var dictionary: [String: Any] {
        var out: [String: Any] = [
            "name": id,
            "version": manifest.version,
            "commands": manifest.commands.map { command in
                ["id": qualified(command.id), "title": command.title]
            },
            "panels": manifest.panels.map { panel in
                var p: [String: Any] = [
                    "id": qualified(panel.id),
                    "title": panel.title,
                    "icon": panel.icon.rawValue,
                    "body": panel.body.dictionary(qualifiedBy: self),
                ]
                if let when = panel.when { p["when"] = when.rawValue }
                return p
            },
        ]
        if let description = manifest.description { out["description"] = description }
        // Resolved host-side so the page renders what it's told rather
        // than re-deriving the fallback rule in JavaScript.
        if let railIcon { out["icon"] = railIcon.rawValue }
        return out
    }
}

private extension PanelPrompt {
    /// What the page needs to draw the field and post what was typed.
    /// `arg` travels because the browser builds `{"args": {arg: value}}`
    /// — it's an object key, never markup.
    var dictionary: [String: Any] {
        var out: [String: Any] = [
            "arg": arg, "submit": submit, "filter": filter,
            "complete": complete, "history": history,
        ]
        if let placeholder { out["placeholder"] = placeholder }
        return out
    }
}

private extension PanelControl {
    /// What the page needs to draw the ticks and post them back.
    var dictionary: [String: Any] {
        ["kind": kind.rawValue, "arg": arg, "submit": submit]
    }
}

private extension PanelBody {
    func dictionary(qualifiedBy plugin: Plugin) -> [String: Any] {
        switch self {
        case .list(let list):
            var body: [String: Any] = ["kind": "list", "source": plugin.qualified(list.source)]
            if let rowAction = list.rowAction { body["rowAction"] = rowAction.rawValue }
            // Absent rather than null when unused, so a panel that
            // predates a field projects byte-for-byte as it always did.
            if let prompt = list.prompt { body["prompt"] = prompt.dictionary }
            if let control = list.control { body["control"] = control.dictionary }
            return body
        }
    }
}
