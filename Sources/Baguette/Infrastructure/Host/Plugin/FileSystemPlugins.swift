import Foundation

/// Production `Plugins` — plugins are directories on disk, each with a
/// `baguette-plugin.json` at its top level. Mirrors
/// `FileSystemChromeStore`: the roots are injectable so tests point at
/// a tmp directory, and the defaults are what a real install has.
///
/// Roots are scanned in order and **later wins** on a name collision:
///
///   1. `~/.baguette/plugins/`   — installed from a marketplace
///   2. `<cwd>/.baguette/plugins/` — checked into the repo, so a team
///      shares its plugins by cloning
///   3. `--plugin-dir <path>`    — local authoring, shadows both
///
/// That ordering is what lets an author iterate on a plugin they also
/// have installed, without uninstalling it first.
struct FileSystemPlugins: Plugins {
    static let manifestFilename = "baguette-plugin.json"

    let roots: [URL]

    init(roots: [URL]) {
        self.roots = roots
    }

    /// The standard roots. `projectDirectory` is `serve`'s working
    /// directory; `extraRoots` carries `--plugin-dir`.
    ///
    /// `bundledRoot` holds the plugins baguette itself ships, so a
    /// fresh install has something in the toolbar rather than an
    /// invisible feature. It sorts **first** — lowest precedence —
    /// so a user's own build of the same plugin shadows it.
    static func standard(
        bundledRoot: URL? = PluginRoot.bundled(),
        installedRoot: URL = BaguetteHome.pluginsRoot,
        projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        extraRoots: [URL] = []
    ) -> FileSystemPlugins {
        FileSystemPlugins(roots: [bundledRoot].compactMap { $0 } + [
            installedRoot,
            projectDirectory.appendingPathComponent(".baguette/plugins"),
        ] + extraRoots)
    }

    /// Scan every root. A root that doesn't exist contributes nothing
    /// — both the installed and per-project roots are routinely absent
    /// and neither is worth failing `serve` over.
    ///
    /// A plugin whose manifest won't parse is **skipped with a
    /// warning**, never thrown. The toolbar is shared: one author's
    /// typo must not blank every other plugin's contributions. Authors
    /// get the precise reason from `baguette plugin validate`.
    func all() throws -> [Plugin] {
        var byID: [String: Plugin] = [:]

        for root in roots {
            for directory in Self.subdirectories(of: root) {
                let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
                guard let data = try? Data(contentsOf: manifestURL) else { continue }
                do {
                    let manifest = try PluginManifest.parsing(json: data)
                    byID[manifest.name] = Plugin(root: directory, manifest: manifest)
                } catch {
                    log("plugin: skipping \(manifestURL.path) — \(error)")
                }
            }
        }

        // Sorted so the toolbar's button order is stable between runs
        // rather than inheriting the filesystem's enumeration order.
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func subdirectories(of root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }
}
