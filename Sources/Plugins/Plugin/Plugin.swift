import BaguetteDevice
import Foundation

/// One installed plugin: where it lives on disk, and what it declares.
///
/// A plugin's identity is its manifest name, and that name is the
/// namespace for everything it contributes. Two plugins may both ship
/// a command called `reload`; they are told apart as `expo:reload` and
/// `detox:reload`. Qualification happens here rather than in the
/// manifest so an author never has to repeat their own plugin name.
struct Plugin: Equatable, Sendable {
    /// Directory containing `baguette-plugin.json`. Also the working
    /// directory a contributed command is spawned in, so relative
    /// `run` paths resolve against the plugin's own files.
    let root: URL
    let manifest: PluginManifest

    var id: String { manifest.name }

    /// The glyph the rail draws for this plugin, collapsed.
    ///
    /// A plugin that names its own icon wears it. One that doesn't —
    /// every manifest written before the rail collapsed — borrows the
    /// panel it leads with, which is nearly always the right face. A
    /// plugin contributing no panels reaches the rail not at all, so
    /// it has no icon and the host decides what that means.
    var railIcon: PluginIcon? {
        manifest.icon ?? manifest.panels.first?.icon
    }

    init(root: URL, manifest: PluginManifest) {
        self.root = root
        self.manifest = manifest
    }

    /// Every contributed command, namespaced.
    var qualifiedCommandIDs: [String] {
        manifest.commands.map { qualified($0.id) }
    }

    /// Namespace a bare command id belonging to this plugin.
    func qualified(_ commandID: String) -> String { "\(id):\(commandID)" }

    /// Resolve a namespaced id (`a11y:audit`) back to the command.
    /// Returns nil for a bare id or another plugin's namespace — the
    /// namespace is the whole point, so an unqualified lookup must
    /// miss rather than guess.
    func command(qualified: String) -> PluginCommand? {
        let parts = qualified.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == Substring(id) else { return nil }
        return manifest.commands.first { $0.id == String(parts[1]) }
    }
}
