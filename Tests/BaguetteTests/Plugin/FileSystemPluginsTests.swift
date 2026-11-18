import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("FileSystemPlugins")
struct FileSystemPluginsTests {

    // MARK: - discovery

    @Test func `should discover a plugin when its directory holds a manifest`() throws {
        let root = try TempRoot()
        try root.install(plugin: "a11y", manifest: Self.manifest(name: "a11y"))

        let plugins = try FileSystemPlugins(roots: [root.url]).all()
        #expect(plugins.map(\.id) == ["a11y"])
    }

    @Test func `should remember the directory a discovered plugin came from`() throws {
        // `root` is the working directory a contributed command runs
        // in, so relative `run` paths resolve against the plugin's own
        // files rather than wherever `baguette serve` was launched.
        let root = try TempRoot()
        try root.install(plugin: "a11y", manifest: Self.manifest(name: "a11y"))

        let plugin = try #require(try FileSystemPlugins(roots: [root.url]).all().first)
        #expect(plugin.root.lastPathComponent == "a11y")
    }

    @Test func `should not treat a directory as a plugin when it holds no manifest`() throws {
        let root = try TempRoot()
        try root.installBareDirectory(named: "not-a-plugin")

        #expect(try FileSystemPlugins(roots: [root.url]).all().isEmpty)
    }

    @Test func `should discover no plugins when the root does not exist`() throws {
        // The per-project and installed roots are both routinely
        // absent. Neither is an error worth failing `serve` over.
        let missing = URL(fileURLWithPath: "/tmp/baguette-does-not-exist-\(UUID().uuidString)")
        #expect(try FileSystemPlugins(roots: [missing]).all().isEmpty)
    }

    // MARK: - one bad plugin doesn't take the rest down

    @Test func `should skip a malformed manifest and still load the good plugins`() throws {
        // The toolbar is shared. A plugin with a typo in its manifest
        // must not blank every other plugin's contributions.
        let root = try TempRoot()
        try root.install(plugin: "broken", manifest: Data("{ not json".utf8))
        try root.install(plugin: "a11y", manifest: Self.manifest(name: "a11y"))

        let plugins = try FileSystemPlugins(roots: [root.url]).all()
        #expect(plugins.map(\.id) == ["a11y"])
    }

    @Test func `should skip a plugin without failing when it declares a newer apiVersion`() throws {
        let root = try TempRoot()
        try root.install(plugin: "future", manifest: Data("""
        { "name": "future", "version": "1.0.0", "apiVersion": 99 }
        """.utf8))
        try root.install(plugin: "a11y", manifest: Self.manifest(name: "a11y"))

        #expect(try FileSystemPlugins(roots: [root.url]).all().map(\.id) == ["a11y"])
    }

    // MARK: - the bundled root

    @Test func `should discover the plugins baguette ships with no configuration`() throws {
        // The reference a11y plugin ships inside the binary's resource
        // bundle so a fresh `brew install` has something in the
        // toolbar. Without this the plugin system is invisible until
        // the user goes and finds one.
        let bundled = try TempRoot()
        try bundled.install(plugin: "a11y", manifest: Self.manifest(name: "a11y"))

        let plugins = try FileSystemPlugins
            .standard(bundledRoot: bundled.url, installedRoot: try TempRoot().url,
                      projectDirectory: try TempRoot().url)
            .all()
        #expect(plugins.map(\.id) == ["a11y"])
    }

    @Test func `should prefer the user's installed build over a bundled plugin of the same name`() throws {
        // The bundled root sorts first precisely so an author can
        // shadow what baguette ships without uninstalling anything.
        let bundled = try TempRoot()
        let installed = try TempRoot()
        try bundled.install(plugin: "a11y", manifest: Self.manifest(name: "a11y", version: "1.0.0"))
        try installed.install(plugin: "a11y", manifest: Self.manifest(name: "a11y", version: "9.9.9"))

        let plugins = try FileSystemPlugins
            .standard(bundledRoot: bundled.url, installedRoot: installed.url,
                      projectDirectory: try TempRoot().url)
            .all()
        #expect(plugins.first?.manifest.version == "9.9.9")
    }

    // MARK: - root precedence

    @Test func `should let a later root override an earlier one when they share a plugin name`() throws {
        // Roots are ordered installed → per-project → --plugin-dir, so
        // a repo can pin its own build of a plugin and an author can
        // shadow both while iterating locally.
        let installed = try TempRoot()
        let project = try TempRoot()
        try installed.install(plugin: "a11y", manifest: Self.manifest(name: "a11y", version: "1.0.0"))
        try project.install(plugin: "a11y", manifest: Self.manifest(name: "a11y", version: "2.0.0"))

        let plugins = try FileSystemPlugins(roots: [installed.url, project.url]).all()
        #expect(plugins.count == 1)
        #expect(plugins.first?.manifest.version == "2.0.0")
    }

    @Test func `should list plugins in a stable alphabetical order`() throws {
        // The toolbar's button order shouldn't shuffle between runs of
        // `serve` just because the filesystem enumerated differently.
        let root = try TempRoot()
        for name in ["zulu", "alpha", "mike"] {
            try root.install(plugin: name, manifest: Self.manifest(name: name))
        }
        #expect(try FileSystemPlugins(roots: [root.url]).all().map(\.id) == ["alpha", "mike", "zulu"])
    }

    // MARK: - helpers

    static func manifest(name: String, version: String = "1.0.0") -> Data {
        Data("""
        { "name": "\(name)", "version": "\(version)", "apiVersion": 1 }
        """.utf8)
    }

    /// A throwaway plugin root under the system temp directory,
    /// removed when the test's value goes out of scope.
    final class TempRoot {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-plugins-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func install(plugin id: String, manifest: Data, under subpath: String = "") throws {
            let dir = subpath.isEmpty
                ? url.appendingPathComponent(id)
                : url.appendingPathComponent(subpath).appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifest.write(to: dir.appendingPathComponent("baguette-plugin.json"))
        }

        func installBareDirectory(named id: String) throws {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(id), withIntermediateDirectories: true
            )
        }
    }
}
