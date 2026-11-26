import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// One thing a plugin adds to the UI, and the executable that answers
/// when the user activates it.
///
/// `run` is an argv — executable first, then arguments — resolved
/// relative to the plugin's own directory. It is *data* until the user
/// clicks: baguette reads it, renders a button titled `title`, and only
/// spawns the process on activation. Nothing here runs at scan time.
struct PluginCommand: Equatable, Sendable {
    /// Unique within the plugin. Namespaced with the plugin's name at
    /// the point of use (`a11y:audit`) so two plugins can both ship a
    /// command called `reload`.
    let id: String
    /// Human label for the button / CLI listing.
    let title: String
    /// Executable + arguments. Never empty — a command that spawns
    /// nothing is a malformed manifest, not a no-op.
    let run: [String]

    init(id: String, title: String, run: [String]) {
        self.id = id
        self.title = title
        self.run = run
    }

    // MARK: - parsing

    static func parsing(dict: [String: Any]) throws -> PluginCommand {
        let id = dict["id"] as? String ?? ""
        // Checked before `run`, because the id is what every later
        // error message names. It's also the namespace half of
        // `plugin:command` — an empty one yields a bare `a11y:` that no
        // lookup resolves and every listing renders blank.
        guard !id.isEmpty else {
            throw PluginManifestError.missingCommandID
        }
        let run = dict["run"] as? [String] ?? []
        guard !run.isEmpty else {
            throw PluginManifestError.emptyCommandRun(id: id)
        }
        return PluginCommand(
            id: id,
            title: dict["title"] as? String ?? id,
            run: run
        )
    }
}
