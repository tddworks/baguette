import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Handler-level coverage for the bakery routes — the pure preview /
/// install helpers, not the Hummingbird `Response` wrappers. Git is
/// mocked; the registry + copy run against a throwaway home.
@Suite("Server bakery routes")
struct ServerBakeryRoutesTests {

    // MARK: - preview

    @Test func `should preview a bakery's menu without trusting the bakery`() async throws {
        let env = try Env()
        let outcome = await Server.previewBakery(reference: "acme/tools", install: env.install)
        guard case .ok(let json) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["commit"] as? String == "c0ffee")
        #expect(parsed?["alreadyTrusted"] as? Bool == false)
        let plugins = try #require(parsed?["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == "hello")
        // Preview must not have recorded anything.
        #expect(try env.registry.bakeries().isEmpty)
    }

    @Test func `should fail a preview of a malformed bakery reference`() async throws {
        let env = try Env()
        let outcome = await Server.previewBakery(reference: "not a ref", install: env.install)
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
    }

    // MARK: - listing

    @Test func `should list the trusted bakeries`() async throws {
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools"), requested: "hello")
        guard case .ok(let json) = Server.listBakeries(home: env.home, installed: []) else {
            Issue.record("expected .ok"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let bakeries = try #require(parsed?["bakeries"] as? [[String: Any]])
        #expect(bakeries.first?["commit"] as? String == "c0ffee")
    }

    @Test func `should mark which of a bakery's plugins are already installed`() async throws {
        // What the shelf draws an Install button from. Deciding it here
        // rather than in the page keeps one rule for "do I have this",
        // and it isn't the same as "is it in installed.json" — a
        // bundled plugin has no provenance record.
        let env = try Env()
        _ = try await env.install.install(ref: try BakeryRef.parse("acme/tools"), requested: "hello")
        guard case .ok(let json) = Server.listBakeries(home: env.home, installed: ["hello"]) else {
            Issue.record("expected .ok"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let bakeries = try #require(parsed?["bakeries"] as? [[String: Any]])
        let plugins = try #require(bakeries.first?["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == "hello")
        #expect(plugins.first?["installed"] as? Bool == true)
    }

    @Test func `should fail rather than list no bakeries when the registry cannot be read`() throws {
        // A corrupt or unreadable `bakeries.json` used to render in the
        // UI as "no bakeries added" — indistinguishable from a fresh
        // install, and the next write would have made it true.
        let env = try Env()
        try FileManager.default.createDirectory(
            at: env.home.appendingPathComponent("bakeries.json"),
            withIntermediateDirectories: true
        )
        guard case .failed = Server.listBakeries(home: env.home, installed: []) else {
            Issue.record("expected .failed"); return
        }
    }

    @Test func `should install and record nothing when previewing a bakery`() async throws {
        // Preview looks and records nothing — not the source, not a
        // plugin. Installing is a separate route with a gate of its
        // own; reaching it by previewing would make that gate
        // decorative.
        let env = try Env()
        _ = await Server.previewBakery(reference: "acme/tools", install: env.install)
        #expect(try env.registry.installed().isEmpty)
        #expect(try env.registry.bakeries().isEmpty)
    }

    // MARK: - installing from a bakery you already trust
    //
    // The browser may install, but only from a source already in
    // `bakeries.json` and only by the id recorded there — never a URL.
    // Installing writes files baguette later executes from, and the
    // only thing in front of a browser route is a set of origin
    // heuristics; naming sources by recorded id is what keeps the blast
    // radius of a wrong one at "a repo you already vetted".

    @Test func `should install a trusted bakery's plugin on the machine`() async throws {
        let env = try Env()
        try env.trust(plugins: ["hello"])

        let outcome = await Server.installFromBakery(
            bakery: "github.com/acme/tools", plugin: "hello",
            home: env.home, install: env.install
        )
        guard case .ok(let json) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["installed"] as? [String] == ["hello"])
        #expect(try env.registry.installed().map(\.name) == ["hello"])
    }

    @Test func `should refuse an install from a bakery that was never trusted`() async throws {
        // The request names an id, so an untrusted one resolves to
        // nothing — no ref is parsed, no remote is contacted, no
        // directory is touched.
        let env = try Env()
        let outcome = await Server.installFromBakery(
            bakery: "github.com/evil/pack", plugin: "hello",
            home: env.home, install: env.install
        )
        guard case .refused = outcome else { Issue.record("expected .refused, got \(outcome)"); return }
        #expect(try env.registry.installed().isEmpty)
        #expect(try env.registry.bakeries().isEmpty)
    }

    @Test func `should refuse an install of a plugin the bakery does not offer`() async throws {
        // Trusting a source is not trusting an arbitrary path in it.
        let env = try Env()
        try env.trust(plugins: ["hello"])

        let outcome = await Server.installFromBakery(
            bakery: "github.com/acme/tools", plugin: "somethingelse",
            home: env.home, install: env.install
        )
        guard case .refused = outcome else { Issue.record("expected .refused, got \(outcome)"); return }
        #expect(try env.registry.installed().isEmpty)
    }

    @Test func `should never echo an untrusted bakery id back into the page when refusing an install`() async throws {
        // The message lands in a modal. It may name what the user
        // already trusted; it must not reflect whatever id was posted.
        let env = try Env()
        let outcome = await Server.installFromBakery(
            bakery: "<img src=x onerror=alert(1)>", plugin: "hello",
            home: env.home, install: env.install
        )
        guard case .refused(let message) = outcome else {
            Issue.record("expected .refused, got \(outcome)"); return
        }
        #expect(!message.contains("<img"))
    }

    // MARK: - fixture (mirrors BakeryInstallTests.Env)

    struct Env {
        let home: URL
        let install: BakeryInstall
        let registry: FileSystemBakeries

        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-route-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            registry = FileSystemBakeries(home: home)

            let checkout = MockCheckout()
            given(checkout).clone(.any, into: .any, at: .any).willProduce { _, into, _ in
                try BakeryInstallTests.Env.writeBakery(into: into, withMenu: true)
                return CheckoutResult(directory: into, commit: "c0ffee")
            }
            given(checkout).pull(at: .any).willReturn("c0ffee")
            install = BakeryInstall(checkout: checkout, home: home)
        }

        /// Trust `acme/tools` the way a terminal `bakery add` would,
        /// without going through the network path.
        func trust(plugins: [String]) throws {
            try registry.record(Bakery(
                id: "github.com/acme/tools", url: "https://github.com/acme/tools.git",
                commit: "c0ffee", plugins: plugins, addedAt: "2026-08-19T00:00:00Z"
            ))
        }
    }
}
