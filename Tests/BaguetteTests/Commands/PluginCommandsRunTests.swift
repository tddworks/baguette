import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette plugin` and `bakery` run against a baguette home a test makes:
/// nothing installed, nothing trusted, and a plugin being authored.
@Suite("Plugin commands run")
struct PluginCommandsRunTests {

    /// A fresh, empty baguette home, and a directory holding one plugin.
    private struct Workspace {
        let home: URL
        let authoring: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("baguette-\(UUID())")
            home = root.appendingPathComponent("home")
            authoring = root.appendingPathComponent("authoring")
            let plugin = authoring.appendingPathComponent("probe-test")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
            try Data("""
            { "name": "probe-test", "version": "1.0.0", "apiVersion": 1,
              "contributes": { "commands": [ { "id": "go", "title": "Go", "run": ["true"] } ] } }
            """.utf8).write(to: plugin.appendingPathComponent(FileSystemPlugins.manifestFilename))
        }

        func remove() { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    }

    private func run(in workspace: Workspace, _ body: () async throws -> Void) async throws -> CommandRun {
        try await BakeryCommand.$home.withValue(workspace.home) {
            try await runWithNoDevice(body)
        }
    }

    @Test func `should list the plugins in the directory given`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) {
            try PluginsCommand.List.parse(["--plugin-dir", workspace.authoring.path]).run()
        }

        #expect(ran.said.first?.contains("probe-test  1.0.0") == true)
    }

    @Test func `should show what a plugin contributes`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) {
            try PluginsCommand.Show.parse(["--plugin-dir", workspace.authoring.path, "probe-test"]).run()
        }

        #expect(ran.said.first?.contains("probe-test:go") == true)
    }

    @Test func `should exit 1 showing a plugin that isn't there`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try PluginsCommand.Show.parse(["nope"]).run() }

        #expect(ran.exit == 1)
        #expect(ran.told == ["No plugin named nope"])
    }

    @Test func `should say a plugin directory's manifest is valid`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let path = workspace.authoring.appendingPathComponent("probe-test").path

        let ran = try await run(in: workspace) { try PluginsCommand.Validate.parse([path]).run() }

        #expect(ran.said == ["probe-test is valid — 1 command(s), 0 panel(s)"])
    }

    @Test func `should exit 1 running a plugin command nothing installed offers`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) {
            try await PluginsCommand.Run.parse(["nope:go", "--udid", "U"]).run()
        }

        #expect(ran.exit == 1)
    }

    @Test func `should say a plugin is removed even when it was never installed`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try PluginsCommand.Remove.parse(["nope"]).run() }

        #expect(ran.said == ["✓ removed nope"])
    }

    @Test func `should say there is nothing to update when nothing is installed`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try await PluginsCommand.Update.parse([]).run() }

        #expect(ran.said == ["Nothing to update."])
    }

    @Test func `should say no bakery is added yet`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try BakeryCommand.List.parse([]).run() }

        #expect(ran.said == ["No bakeries added. Add one with: baguette bakery add owner/repo"])
    }

    @Test func `should say no bakery is added when asked what is outdated`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try await BakeryCommand.Outdated.parse([]).run() }

        #expect(ran.said == ["No bakeries added."])
    }

    @Test func `should say there is no bakery to update when none is added`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try await BakeryCommand.Update.parse([]).run() }

        #expect(ran.said == ["Nothing to update."])
    }

    @Test func `should forget a bakery, saying its installed plugins remain`() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }

        let ran = try await run(in: workspace) { try BakeryCommand.Remove.parse(["owner/repo"]).run() }

        #expect(ran.said == ["✓ forgot github.com/owner/repo (its installed plugins remain)"])
    }
}

/// `run(reaching:_:)` with no device, named apart from the suite's own `run`.
private func runWithNoDevice(_ body: () async throws -> Void) async throws -> CommandRun {
    try await run(reaching: reaching(noDevices()), body)
}
