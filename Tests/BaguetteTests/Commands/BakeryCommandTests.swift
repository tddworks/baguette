import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette bakery …` and `baguette plugin install|update|show|validate|run`,
/// end to end against a throwaway `~/.baguette` with git mocked — what each
/// says on stdout and stderr, and when it fails.
@Suite("Bakery and plugin commands")
struct BakeryCommandTests {

    private typealias Env = BakeryInstallTests.Env

    private static func bakery(_ id: String = "github.com/acme/tools", commit: String = "c0ffee") -> Bakery {
        Bakery(id: id, url: "https://\(id).git", commit: commit, plugins: ["hello"], addedAt: "2026-01-01")
    }

    // MARK: - bakery add

    @Test func `should add a bakery the user trusts, saying what it offers and how to install from it`() async throws {
        let env = try Env()
        let output = OutputLines()

        try await BakeryCommand.Add.add(
            reference: "acme/tools", accept: true, using: env.install,
            confirm: { _ in Issue.record("asked although accepted"); return false }, output: output.sink)

        #expect(output.said == [
            "acme/tools — offers: hello",
            "✓ added github.com/acme/tools @ c0ffee",
            "  install a plugin with: baguette plugin install hello",
        ])
        #expect(try env.registry.bakeries().map(\.id) == ["github.com/acme/tools"])
    }

    @Test func `should add nothing when the user declines to trust a new bakery`() async throws {
        let env = try Env()
        let output = OutputLines()
        let asked = Lines()

        await #expect(throws: (any Error).self) {
            try await BakeryCommand.Add.add(
                reference: "acme/tools", accept: false, using: env.install,
                confirm: { asked.add($0); return false }, output: output.sink)
        }

        #expect(asked.all.count == 1)
        #expect(output.warned == ["Not added."])
        #expect(try env.registry.bakeries().isEmpty)
    }

    // MARK: - bakery list

    @Test func `should say how to add a bakery when none is trusted`() throws {
        let env = try Env()
        let output = OutputLines()

        try BakeryCommand.List.list(registry: env.registry, output: output.sink)

        #expect(output.said == ["No bakeries added. Add one with: baguette bakery add owner/repo"])
    }

    @Test func `should list each trusted bakery with its pinned commit and what it offers`() throws {
        let env = try Env()
        try env.registry.record(Self.bakery())
        let output = OutputLines()

        try BakeryCommand.List.list(registry: env.registry, output: output.sink)

        #expect(output.said == ["github.com/acme/tools  @c0ffee  offers: hello"])
    }

    // MARK: - bakery remove

    @Test func `should forget a bakery and say its plugins stay installed`() throws {
        let env = try Env()
        try env.registry.record(Self.bakery())
        let output = OutputLines()

        try BakeryCommand.Remove.remove(reference: "acme/tools", registry: env.registry, output: output.sink)

        #expect(output.said == ["✓ forgot github.com/acme/tools (its installed plugins remain)"])
        #expect(try env.registry.bakeries().isEmpty)
    }

    // MARK: - bakery outdated

    @Test func `should say no bakery is trusted when checking for updates with none`() async throws {
        let env = try Env()
        let output = OutputLines()

        try await BakeryCommand.Outdated.outdated(registry: env.registry, checkout: MockCheckout(), output: output.sink)

        #expect(output.said == ["No bakeries added."])
    }

    @Test func `should list each bakery's state and how to re-pin when one has moved`() async throws {
        let env = try Env()
        try env.registry.record(Self.bakery(commit: "aaaaaaa1"))
        let checkout = MockCheckout()
        given(checkout).head(of: .any).willReturn("bbbbbbb2")
        let output = OutputLines()

        try await BakeryCommand.Outdated.outdated(registry: env.registry, checkout: checkout, output: output.sink)

        #expect(output.said == [
            BakeryUpdate(id: "github.com/acme/tools", pinned: "aaaaaaa1", head: "bbbbbbb2").line,
            "",
            "Re-pin with: baguette bakery update <owner/repo>",
            "Nothing changes on your machine until you do.",
        ])
    }

    @Test func `should list a bakery it couldn't reach without offering to re-pin it`() async throws {
        let env = try Env()
        try env.registry.record(Self.bakery())
        let checkout = MockCheckout()
        given(checkout).head(of: .any).willThrow(CocoaError(.fileNoSuchFile))
        let output = OutputLines()

        try await BakeryCommand.Outdated.outdated(registry: env.registry, checkout: checkout, output: output.sink)

        #expect(output.said == [BakeryUpdate(id: "github.com/acme/tools", pinned: "c0ffee", head: nil).line])
    }

    // MARK: - bakery update

    @Test func `should re-pin the bakery named`() async throws {
        let env = try Env()
        _ = try await env.install.add(try BakeryRef.parse("acme/tools"))
        let output = OutputLines()

        try await BakeryCommand.Update.update(
            reference: "acme/tools", using: env.install, registry: env.registry, output: output.sink)

        #expect(output.said == ["✓ github.com/acme/tools @ c0ffee"])
    }

    @Test func `should say there is nothing to update when no trusted bakery matches`() async throws {
        let env = try Env()
        let output = OutputLines()

        try await BakeryCommand.Update.update(
            reference: nil, using: env.install, registry: env.registry, output: output.sink)

        #expect(output.said == ["Nothing to update."])
    }

    // MARK: - trust prompt

    @Test func `should take yes or y in any case as consent`() {
        #expect(TrustPrompt.accepts("y"))
        #expect(TrustPrompt.accepts(" YES "))
    }

    @Test func `should take anything else, or no answer, as a refusal`() {
        #expect(!TrustPrompt.accepts("n"))
        #expect(!TrustPrompt.accepts(""))
        #expect(!TrustPrompt.accepts(nil))
    }

    // MARK: - plugin install

    @Test func `should install a plugin by reference and say where it came from`() async throws {
        let env = try Env()
        let output = OutputLines()

        try await PluginsCommand.Install.install(
            target: "acme/tools/hello", accept: true, using: env.install,
            confirm: { _ in false }, output: output.sink)

        #expect(output.said == [
            "✓ installed hello @ c0ffee (from github.com/acme/tools)",
            "  refresh the browser to see it in the plugins rail",
        ])
    }

    @Test func `should install a plugin by bare name from a bakery already trusted, without asking`() async throws {
        let env = try Env()
        _ = try await env.install.add(try BakeryRef.parse("acme/tools"))
        let output = OutputLines()

        try await PluginsCommand.Install.install(
            target: "hello", accept: false, using: env.install,
            confirm: { _ in Issue.record("asked for a trusted bakery"); return false }, output: output.sink)

        #expect(output.said.first == "✓ installed hello @ c0ffee (from github.com/acme/tools)")
    }

    @Test func `should install nothing when the user declines a new bakery`() async throws {
        let env = try Env()
        let output = OutputLines()

        await #expect(throws: (any Error).self) {
            try await PluginsCommand.Install.install(
                target: "acme/tools/hello", accept: false, using: env.install,
                confirm: { _ in false }, output: output.sink)
        }

        #expect(output.warned == ["Not installed."])
    }

    // MARK: - plugin update

    @Test func `should say there is nothing to update when no plugin is installed`() async throws {
        let env = try Env()
        let output = OutputLines()

        try await PluginsCommand.Update.update(
            name: nil, using: env.install, registry: env.registry, output: output.sink)

        #expect(output.said == ["Nothing to update."])
    }

    @Test func `should re-install each plugin from its bakery`() async throws {
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools/hello"), requested: nil)
        let output = OutputLines()

        try await PluginsCommand.Update.update(
            name: "hello", using: env.install, registry: env.registry, output: output.sink)

        #expect(output.said == ["✓ hello @ c0ffee"])
    }

    @Test func `should skip a plugin whose bakery is no longer trusted, saying so`() async throws {
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools/hello"), requested: nil)
        try env.registry.forget(bakeryID: "github.com/acme/tools")
        let output = OutputLines()

        try await PluginsCommand.Update.update(
            name: nil, using: env.install, registry: env.registry, output: output.sink)

        #expect(output.warned == ["skipping hello: its bakery github.com/acme/tools is no longer trusted"])
        #expect(output.said.isEmpty)
    }

    // MARK: - plugin show

    @Test func `should show what an installed plugin contributes`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([PluginsCommandTests.plugin(name: "a11y", version: "1.0.0")])
        let output = OutputLines()

        try PluginsCommand.Show.show(name: "a11y", in: plugins, output: output.sink)

        #expect(output.said == [PluginsCommand.detail(PluginsCommandTests.plugin(name: "a11y", version: "1.0.0"))])
    }

    @Test func `should fail to show a plugin nobody installed, naming it`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([])
        let output = OutputLines()

        #expect(throws: (any Error).self) {
            try PluginsCommand.Show.show(name: "ghost", in: plugins, output: output.sink)
        }
        #expect(output.warned == ["No plugin named ghost"])
    }

    // MARK: - plugin validate

    @Test func `should say a plugin directory with a good manifest is valid`() throws {
        let dir = try Self.pluginDirectory(manifest: PluginsCommandTests.manifestJSON)
        let output = OutputLines()

        try PluginsCommand.Validate.validate(directory: dir.path, output: output.sink)

        #expect(output.said == ["a11y is valid — 1 command(s), 1 panel(s)"])
    }

    @Test func `should fail a plugin directory with no manifest`() throws {
        let dir = try Self.pluginDirectory(manifest: nil)
        let output = OutputLines()

        #expect(throws: (any Error).self) {
            try PluginsCommand.Validate.validate(directory: dir.path, output: output.sink)
        }
        #expect(output.warned == ["No \(FileSystemPlugins.manifestFilename) at \(dir.path)"])
    }

    @Test func `should fail a manifest that doesn't parse, saying why`() throws {
        let dir = try Self.pluginDirectory(manifest: Data("{}".utf8))
        let output = OutputLines()

        #expect(throws: (any Error).self) {
            try PluginsCommand.Validate.validate(directory: dir.path, output: output.sink)
        }
        #expect(output.warned.first?.hasPrefix("Invalid manifest: ") == true)
    }

    // MARK: - plugin run

    @Test func `should print a plugin's answer and succeed when it reports success`() throws {
        let output = OutputLines()

        try PluginsCommand.Run.report(.ok(PluginResult(ok: true, message: "done")), output: output.sink)

        #expect(output.said == [PluginResult(ok: true, message: "done").json])
    }

    @Test func `should print a plugin's answer and fail when it reports failure`() {
        let output = OutputLines()

        #expect(throws: (any Error).self) {
            try PluginsCommand.Run.report(.ok(PluginResult(ok: false, message: "nope")), output: output.sink)
        }
        #expect(output.said == [PluginResult(ok: false, message: "nope").json])
    }

    @Test func `should fail a plugin that didn't answer, saying why`() {
        let output = OutputLines()

        #expect(throws: (any Error).self) {
            try PluginsCommand.Run.report(.unknownCommand(id: "x:y"), output: output.sink)
        }
        #expect(output.warned == [#"no installed plugin contributes "x:y""#])
    }

    // MARK: - helpers

    private static func pluginDirectory(manifest: Data?) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baguette-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: dir.appendingPathComponent(FileSystemPlugins.manifestFilename))
        }
        return dir
    }
}
