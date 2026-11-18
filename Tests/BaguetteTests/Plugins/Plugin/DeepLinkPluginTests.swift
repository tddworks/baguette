import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The deep-link plugin baguette publishes, parsed exactly as an
/// installed copy would be.
///
/// It ships in this repo's own bakery (`baguette.json` → `plugins/`)
/// rather than in `Sources/Baguette/Resources/Plugins/`, which is what
/// makes the a11y audit arrive bundled. That's deliberate: it's an
/// official plugin you still choose to install. The cost of that choice
/// is that nothing in the build would notice a manifest that stopped
/// parsing — `serve` skips a bad manifest with a log line, so a broken
/// official plugin would present as a rail entry that silently never
/// appears. These tests are what notices.
@Suite("DeepLink plugin")
struct DeepLinkPluginTests {

    /// The repo root, walked up from this file rather than from the
    /// process's working directory — `swift test` doesn't promise one.
    private static var repoRoot: URL {
        RepoRoot.url
    }

    private static let pluginDirectory = repoRoot.appendingPathComponent("plugins/deeplink")

    private func manifest() throws -> PluginManifest {
        try PluginManifest.parsing(json: try Data(
            contentsOf: Self.pluginDirectory
                .appendingPathComponent(FileSystemPlugins.manifestFilename)
        ))
    }

    @Test func `should load the published deeplink manifest with nothing to warn about`() throws {
        let manifest = try manifest()
        #expect(manifest.name == "deeplink")
        #expect(manifest.apiVersion == 1)
        #expect(manifest.icon == .link)
        // A warning here means a mistyped icon silently degrading to the
        // puzzle piece — fine for a stranger's plugin, not for ours.
        #expect(manifest.warnings.isEmpty)
    }

    @Test func `should ask for the power to open links and nothing more`() throws {
        // The pre-install trust screen (`baguette plugin show`) prints
        // this list. It must not creep: `apps` next door installs
        // software, and `input` can tap through any consent dialog.
        #expect(try manifest().capabilities == [.openURL])
    }

    @Test func `should offer a panel with a field to type a link into`() throws {
        let panel = try #require(try manifest().panels.first)
        #expect(panel.when == .simulatorBooted)
        guard case .list(let list) = panel.body else {
            Issue.record("expected a list body"); return
        }
        #expect(list.source == "open")
        // The rows are a completion source, not a launcher. Clicking
        // `account://` fills the field so you can type the path —
        // opening a bare scheme with no path is almost never what
        // anyone means, and it used to be all a click could do.
        #expect(list.rowAction == .fill)
        #expect(list.prompt?.arg == "url")
        #expect(list.prompt?.filter == true)
    }

    @Test func `should run a command script that actually exists in the plugin`() throws {
        // A manifest naming a script that didn't ship parses perfectly
        // and then fails on first click, which is the worst time to find
        // out. The interpreter is absolute; the script is relative to
        // the plugin directory, which is the command's cwd.
        let command = try #require(try manifest().commands.first)
        #expect(command.id == "open")
        let script = try #require(command.run.last)
        #expect(
            FileManager.default.fileExists(
                atPath: Self.pluginDirectory.appendingPathComponent(script).path
            ),
            "\(script) is named by the manifest but not present in plugins/deeplink"
        )
    }

    @Test func `should be offered by the repo's bakery menu`() throws {
        // `baguette plugin install tddworks/baguette/deeplink` resolves
        // through this file. A plugin the menu doesn't name is
        // unreachable however good its manifest is.
        let menu = try BakeryMenu.parsing(json: try Data(
            contentsOf: Self.repoRoot.appendingPathComponent("baguette.json")
        ))
        let entry = try #require(menu.entry(named: "deeplink"))
        #expect(entry.path == "plugins/deeplink")
    }

    @Test func `should not ship bundled with baguette`() throws {
        // The whole point: official, and still installed on purpose. If
        // this directory ever appears, the plugin starts arriving with
        // every build and the distinction is gone.
        let bundled = Self.repoRoot
            .appendingPathComponent(PluginRoot.sourceTreePath)
            .appendingPathComponent("deeplink")
        #expect(!FileManager.default.fileExists(atPath: bundled.path))
    }
}
