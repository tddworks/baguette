import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Coverage for the install orchestrator. Git is mocked (`MockCheckout`
/// writes a fixture bakery into the requested clone dir); the registry
/// and the plugin copy run against a real throwaway `~/.baguette`, the
/// same way `FileSystemPluginsTests` uses a real temp root.
@Suite("BakeryInstall")
struct BakeryInstallTests {

    // MARK: - add a source

    @Test func `should trust an added bakery at its pinned commit`() async throws {
        let env = try Env()
        let ref = try BakeryRef.parse("acme/tools")
        let bakery = try await env.install.add(ref)

        #expect(bakery.id == "github.com/acme/tools")
        #expect(bakery.commit == "c0ffee")
        #expect(bakery.plugins == ["hello"])
        #expect(try env.registry.bakeries().map(\.id) == ["github.com/acme/tools"])
    }

    @Test func `should leave the trusted list unchanged when previewing a bakery`() async throws {
        // The browser previews before the user consents, so preview
        // must be side-effect-free on the trusted list.
        let env = try Env()
        let preview = try await env.install.preview(try BakeryRef.parse("acme/tools"))
        #expect(preview.commit == "c0ffee")
        #expect(preview.menu.entries.map(\.name) == ["hello"])
        #expect(preview.alreadyTrusted == false)
        #expect(try env.registry.bakeries().isEmpty)
    }

    @Test func `should refuse to add a repo without baguette.json as a bakery`() async throws {
        let env = try Env(writeMenu: false)
        await #expect(throws: BakeryMenuError.self) {
            _ = try await env.install.add(try BakeryRef.parse("acme/tools"))
        }
    }

    // MARK: - install a plugin

    @Test func `should copy an installed plugin into the plugins root where it is discoverable`() async throws {
        let env = try Env()
        let ref = try BakeryRef.parse("acme/tools/hello")
        let installed = try await env.install.install(ref: ref, requested: nil)

        #expect(installed.map(\.name) == ["hello"])
        let manifest = env.home
            .appendingPathComponent("plugins/hello/baguette-plugin.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        // The copied plugin is now discoverable by the normal scanner.
        let discovered = try FileSystemPlugins(roots: [env.home.appendingPathComponent("plugins")]).all()
        #expect(discovered.map(\.id) == ["hello"])
    }

    @Test func `should record an installed plugin's provenance and trust its source`() async throws {
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools/hello"), requested: nil)

        let provenance = try #require(try env.registry.installed().first)
        #expect(provenance.name == "hello")
        #expect(provenance.bakery == "github.com/acme/tools")
        #expect(provenance.commit == "c0ffee")
        // A direct install trusts the bakery it pulled from.
        #expect(try env.registry.bakeries().map(\.id) == ["github.com/acme/tools"])
    }

    @Test func `should refuse an unknown plugin name before copying anything`() async throws {
        let env = try Env()
        await #expect(throws: InstallPlanError.self) {
            _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools"), requested: "ghost")
        }
        #expect(try env.registry.installed().isEmpty)
    }

    // MARK: - install by bare name across trusted bakeries

    @Test func `should install a bare plugin name from the trusted bakery that offers it`() async throws {
        // `plugin install hello` after the bakery was added — no ref,
        // no second trust prompt.
        let env = try Env()
        _ = try await env.install.add(try BakeryRef.parse("acme/tools"))

        let installed = try await env.install.installByName("hello")
        #expect(installed.map(\.name) == ["hello"])
        #expect(FileManager.default.fileExists(
            atPath: env.home.appendingPathComponent("plugins/hello/baguette-plugin.json").path))
    }

    @Test func `should refuse a bare plugin name when no trusted bakery offers it`() async throws {
        let env = try Env()
        _ = try await env.install.add(try BakeryRef.parse("acme/tools"))
        await #expect(throws: BakeryResolveError.notOffered(name: "ghost")) {
            _ = try await env.install.installByName("ghost")
        }
    }

    // MARK: - remove

    @Test func `should delete a removed plugin and clear its provenance`() async throws {
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools/hello"), requested: nil)

        try env.install.remove(name: "hello")
        #expect(!FileManager.default.fileExists(
            atPath: env.home.appendingPathComponent("plugins/hello").path))
        #expect(try env.registry.installed().isEmpty)
    }

    // MARK: - fixture environment

    // MARK: - the pin

    @Test func `should fetch the recorded commit when installing from an already-trusted bakery`() async throws {
        // Trust was granted to a specific commit. Taking HEAD on the
        // second install would mean a bakery accepted months ago
        // silently delivers whatever it holds today — the pin only means
        // anything if it's what we actually fetch.
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools"), requested: "hello")
        #expect(env.pins.value == [nil])          // first contact: nothing to demand

        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools"), requested: "hello")
        #expect(env.pins.value == [nil, "c0ffee"])
    }

    final class Pins: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String?] = []
        func record(_ commit: String?) {
            lock.lock(); defer { lock.unlock() }
            seen.append(commit)
        }
        var value: [String?] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
    }

    struct Env {
        let home: URL
        let install: BakeryInstall
        let registry: FileSystemBakeries
        /// The `at:` argument of each clone, in order.
        let pins = Pins()

        init(writeMenu: Bool = true) throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-install-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            registry = FileSystemBakeries(home: home)

            let checkout = MockCheckout()
            let homeCopy = home
            let pinsCopy = pins
            given(checkout).clone(.any, into: .any, at: .any).willProduce { _, into, at in
                pinsCopy.record(at)
                try Env.writeBakery(into: into, withMenu: writeMenu)
                return CheckoutResult(directory: into, commit: "c0ffee")
            }
            given(checkout).pull(at: .any).willReturn("c0ffee")

            install = BakeryInstall(checkout: checkout, home: homeCopy)
        }

        /// Lay a minimal one-plugin bakery down at `dir`.
        static func writeBakery(into dir: URL, withMenu: Bool) throws {
            let pluginDir = dir.appendingPathComponent("plugins/hello/bin")
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try Data(#"echo hi"#.utf8).write(to: pluginDir.appendingPathComponent("run.sh"))
            try Data("""
            { "name": "hello", "version": "1.0.0", "apiVersion": 1,
              "contributes": { "commands": [ { "id": "go", "title": "Go", "run": ["true"] } ] } }
            """.utf8).write(to: dir.appendingPathComponent("plugins/hello/baguette-plugin.json"))

            if withMenu {
                try Data("""
                { "name": "acme/tools",
                  "plugins": [ { "name": "hello", "path": "plugins/hello" } ] }
                """.utf8).write(to: dir.appendingPathComponent("baguette.json"))
            }
        }
    }
}
