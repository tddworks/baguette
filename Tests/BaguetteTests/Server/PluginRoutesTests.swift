import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Handler-level coverage for the plugin routes, matching the
/// house style: the pure parse + dispatch helpers are tested, not the
/// Hummingbird `Response` wrappers.
@Suite("Server plugin routes")
struct PluginRoutesTests {

    // MARK: - describe-ui.json

    @Test func `should describe the UI tree to a plugin that has no WebSocket`() throws {
        // `describe_ui` was WS-only, which put the AX tree out of reach
        // of a subprocess plugin entirely. This route is what makes the
        // reference a11y plugin possible.
        let outcome = Server.describeUI(udid: "U", point: nil, devices: Self.simulators())
        guard case .ok(let json) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == true)
        let tree = try #require(parsed?["tree"] as? [String: Any])
        #expect(tree["role"] as? String == "AXApplication")
    }

    @Test func `should describe the element under a point when one is given`() throws {
        let ax = MockAccessibility()
        given(ax).describeAt(point: .value(Point(x: 10, y: 20)))
            .willReturn(AXNode(role: "AXButton", frame: Self.frame))
        let outcome = Server.describeUI(
            udid: "U", point: Point(x: 10, y: 20), devices: Self.simulators(ax: ax)
        )
        guard case .ok(let json) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(json.contains("AXButton"))
    }

    @Test func `should report an unknown device when describing the UI of an unknown udid`() throws {
        #expect(Server.describeUI(udid: "nope", point: nil, devices: routeDevices()) == .unknownDevice)
    }

    @Test func `should report no data when describing the UI with nothing frontmost`() throws {
        // SpringBoard idle or a boot in progress. Not an error — the
        // plugin should say "nothing to audit", not "audit failed".
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(nil)
        #expect(Server.describeUI(udid: "U", point: nil, devices: Self.simulators(ax: ax)) == .noData)
    }

    // MARK: - running a command

    @Test func `should answer a plugin command with the plugin's rows as JSON`() async throws {
        let outcome = await Server.runPlugin(
            qualified: "a11y:audit",
            context: Self.context,
            plugins: Self.plugins(),
            subprocess: { Self.subprocess(stdout: #"{"ok":true,"rows":[{"title":"No label"}]}"#) }
        )
        guard case .ok(let json) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == true)
        let rows = try #require(parsed?["rows"] as? [[String: Any]])
        #expect(rows.first?["title"] as? String == "No label")
    }

    @Test func `should report an unknown plugin command as not found`() async throws {
        let outcome = await Server.runPlugin(
            qualified: "a11y:nope", context: Self.context, plugins: Self.plugins(),
            subprocess: { Self.subprocess() }
        )
        #expect(outcome == .unknown(#"no installed plugin contributes "a11y:nope""#))
    }

    @Test func `should report a plugin command that failed to run with its exit status`() async throws {
        let outcome = await Server.runPlugin(
            qualified: "a11y:audit", context: Self.context, plugins: Self.plugins(),
            subprocess: { Self.subprocess(stdout: "boom", exitCode: 3) }
        )
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
        #expect(message.contains("exited 3"))
    }

    // MARK: - capability grants

    @Test func `should grant a running plugin command exactly its manifest's capabilities`() async throws {
        // The token the plugin receives must be a live grant carrying
        // exactly what the manifest declared — that's what the plugin
        // API checks.
        let grants = PluginGrants()
        let seen = SeenToken()
        _ = await Server.runPlugin(
            qualified: "a11y:audit",
            context: Self.context,
            plugins: Self.plugins(capabilities: [.describeUI]),
            grants: grants,
            subprocess: { Self.subprocess(recording: seen, grants: grants) }
        )
        #expect(seen.capabilities == [.describeUI])
    }

    @Test func `should revoke the plugin's grant once the command finishes`() async throws {
        // A leaked token is useless after the run it belonged to.
        let grants = PluginGrants()
        let seen = SeenToken()
        _ = await Server.runPlugin(
            qualified: "a11y:audit",
            context: Self.context,
            plugins: Self.plugins(capabilities: [.describeUI]),
            grants: grants,
            subprocess: { Self.subprocess(recording: seen, grants: grants) }
        )
        let token = try #require(seen.token)
        #expect(grants.capabilities(for: token) == nil)
    }

    /// Captures the token handed to the child, and what it could do
    /// while the child was running.
    final class SeenToken: @unchecked Sendable {
        var token: String?
        var capabilities: [PluginCapability]?
    }

    // MARK: - helpers

    static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 100, height: 100))
    static let context = PluginDispatch.Context(
        serverURL: "http://127.0.0.1:8421", udid: "U", token: "tok"
    )

    static func simulators(ax: MockAccessibility? = nil) -> any Devices {
        let accessibility = ax ?? {
            let mock = MockAccessibility()
            given(mock).describeAll().willReturn(AXNode(role: "AXApplication", frame: frame))
            return mock
        }()
        return routeDevices { $0.register(.accessibility) { accessibility } }
    }

    static func plugins(capabilities: [PluginCapability] = []) -> MockPlugins {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(
                root: URL(fileURLWithPath: "/tmp/plugins/a11y"),
                manifest: PluginManifest(
                    name: "a11y", version: "1.0.0", apiVersion: 1,
                    capabilities: capabilities,
                    commands: [PluginCommand(id: "audit", title: "Audit", run: ["true"])]
                )
            )
        ])
        return plugins
    }

    static func subprocess(stdout: String = #"{"ok":true}"#, exitCode: Int32 = 0) -> MockSubprocess {
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, _, _, _, _, onBytes, onExit in
            onBytes(Data(stdout.utf8))
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return sub
    }

    /// A child that reports what its handed token could do *while it
    /// was running* — the grant is revoked after, so it has to be
    /// sampled from inside the invocation.
    static func subprocess(recording seen: SeenToken, grants: PluginGrants) -> MockSubprocess {
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, _, _, env, _, onBytes, onExit in
            let token = env["BAGUETTE_TOKEN"]
            seen.token = token
            seen.capabilities = token.flatMap { grants.capabilities(for: $0) }
            onBytes(Data(#"{"ok":true}"#.utf8))
            onExit(0)
        }
        given(sub).terminate().willReturn()
        return sub
    }
}
