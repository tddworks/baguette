import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `PluginRoot` finds the plugins baguette itself ships — the same
/// three-step lookup `WebRoot` uses for web assets, and pinned here for
/// the same reason: the fallbacks are invisible until one silently stops
/// resolving and the bundled a11y plugin quietly disappears from the
/// rail.
///
/// `.serialized` because `setenv` is process-global; two of these
/// running concurrently would read each other's override.
@Suite("PluginRoot", .serialized)
struct PluginRootTests {

    @Test func `should use the BAGUETTE_PLUGIN_DIR override over every other plugin location`() throws {
        // Step 1 of the lookup. Also how a plugin author points baguette
        // at a working tree without installing anything.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        setenv("BAGUETTE_PLUGIN_DIR", tmp.path, 1)
        defer { unsetenv("BAGUETTE_PLUGIN_DIR") }

        #expect(PluginRoot.bundled()?.path == tmp.path)
    }

    @Test func `should find no bundled plugins when BAGUETTE_PLUGIN_DIR names nothing that exists`() {
        // Not a fallback to the source tree: naming a directory that
        // isn't there is a mistake worth surfacing as "no plugins"
        // rather than silently loading a different set than asked for.
        setenv("BAGUETTE_PLUGIN_DIR", "/definitely/not/a/real/directory", 1)
        defer { unsetenv("BAGUETTE_PLUGIN_DIR") }

        #expect(PluginRoot.bundled() == nil)
    }

    @Test func `should refuse BAGUETTE_PLUGIN_DIR when it points at a file rather than a directory`() throws {
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("not-a-directory.txt")
        try Data("x".utf8).write(to: file)

        setenv("BAGUETTE_PLUGIN_DIR", file.path, 1)
        defer { unsetenv("BAGUETTE_PLUGIN_DIR") }

        #expect(PluginRoot.bundled() == nil)
    }

    // MARK: - the source-tree walk
    //
    // Step 2 of the lookup, and the dev affordance that lets you edit a
    // bundled plugin and re-run without rebuilding resources. Driven
    // with an explicit starting directory so the walk is exercised
    // without `dladdr` — the walk is the part that can be wrong.

    @Test func `should find the source tree's plugins in the package root above the executable`() throws {
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A miniature package: <root>/Sources/Baguette/Resources/Plugins
        // with the executable three levels down in .build/debug.
        let plugins = tmp.appendingPathComponent(PluginRoot.sourceTreePath)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let exeDir = tmp.appendingPathComponent(".build/debug")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)

        #expect(PluginRoot.sourceTreeRoot(startingAt: exeDir)?.path == plugins.path)
    }

    @Test func `should give up looking for the source tree rather than climb to the filesystem root`() throws {
        // A release install has no package above it. Walking forever
        // would eventually hit someone else's `Sources/` directory.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let deep = tmp.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        #expect(PluginRoot.sourceTreeRoot(startingAt: deep) == nil)
    }

    @Test func `should stop looking for the source tree at the configured depth`() throws {
        // The package root sits deeper than the walk is allowed to
        // climb, so it must not be found — this is what bounds the
        // search rather than the loop happening to terminate.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let plugins = tmp.appendingPathComponent(PluginRoot.sourceTreePath)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let exeDir = tmp.appendingPathComponent("one/two/three")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)

        #expect(PluginRoot.sourceTreeRoot(startingAt: exeDir, depth: 2) == nil)
        #expect(PluginRoot.sourceTreeRoot(startingAt: exeDir, depth: 4)?.path == plugins.path)
    }

    // MARK: - the sidecar bundle

    @Test func `should find no bundled plugins when no sidecar bundle sits beside the executable`() throws {
        // Step 3, and the common case for a binary-only install with no
        // resource bundle. Must be nil rather than a `fatalError`, which
        // is what `Bundle.module` would do here.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(PluginRoot.sidecarRoot(nextTo: tmp) == nil)
    }

    @Test func `should find no bundled plugins when the sidecar is not a loadable bundle`() throws {
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Right name, not a bundle.
        try Data("not a bundle".utf8)
            .write(to: tmp.appendingPathComponent("Baguette_Baguette.bundle"))

        #expect(PluginRoot.sidecarRoot(nextTo: tmp) == nil)
    }

    @Test func `should find the bundled plugins in a sidecar bundle that carries a Plugins directory`() throws {
        // The shape a release install actually has: SPM's resource
        // bundle sitting next to the binary, with `Plugins/` inside.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resources = tmp
            .appendingPathComponent("Baguette_Baguette.bundle")
            .appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent(PluginRoot.bundleDirectoryName),
            withIntermediateDirectories: true
        )

        let root = try #require(PluginRoot.sidecarRoot(nextTo: tmp))
        #expect(root.lastPathComponent == PluginRoot.bundleDirectoryName)
    }

    @Test func `should find no bundled plugins when the sidecar bundle has no Plugins directory`() throws {
        // A build that shipped web assets but no plugins. Not an error —
        // just no bundled plugins.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Baguette_Baguette.bundle/Contents/Resources"),
            withIntermediateDirectories: true
        )

        #expect(PluginRoot.sidecarRoot(nextTo: tmp) == nil)
    }

    // MARK: - the whole lookup

    @Test func `should find the running build's own bundled plugins when no override is set`() throws {
        // End-to-end through `dladdr`: the test binary lives under
        // `.build/`, so the walk must reach the package root and land on
        // the directory holding the reference a11y plugin. This is the
        // affordance that lets you edit a bundled plugin and re-run
        // without rebuilding resources — silently losing it would only
        // show up as the rail going empty.
        unsetenv("BAGUETTE_PLUGIN_DIR")

        let root = try #require(PluginRoot.bundled())
        let manifest = root
            .appendingPathComponent("a11y")
            .appendingPathComponent("baguette-plugin.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test func `should discover plugins from wherever the bundled root resolves to`() throws {
        // The point of the whole lookup: `FileSystemPlugins.standard`
        // starts from it, so an override lands real plugins in the rail.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.writePlugin(named: "solo", into: tmp)

        setenv("BAGUETTE_PLUGIN_DIR", tmp.path, 1)
        defer { unsetenv("BAGUETTE_PLUGIN_DIR") }

        let found = try FileSystemPlugins.standard().all()
        #expect(found.contains { $0.id == "solo" })
    }

    // MARK: - helpers

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writePlugin(named name: String, into root: URL) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {"name":"\(name)","version":"1.0.0","apiVersion":1,
         "contributes":{"commands":[{"id":"go","title":"Go","run":["true"]}]}}
        """
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("baguette-plugin.json"))
    }
}
