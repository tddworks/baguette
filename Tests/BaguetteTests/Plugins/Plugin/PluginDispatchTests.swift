import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Orchestration coverage for `PluginDispatch` — argv assembly, the
/// pinned working directory, the injected environment, and the
/// stdout handshake. The irreducible spawn lives in `HostSubprocess`
/// (integration-only), so every branch here runs through
/// `MockSubprocess`.
@Suite("PluginDispatch")
struct PluginDispatchTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var workingDirectory: URL?
        var environment: [String: String]?
        var stdin: Data?
    }

    // MARK: - how the child is spawned

    @Test func `should run the plugin command through env so PATH is honoured`() async throws {
        // `run` is an argv, not an absolute path — a plugin says
        // ["node", "bin/audit.js"] and shouldn't have to know where
        // the user's node lives. `/usr/bin/env` does the lookup.
        let (outcome, captures) = await Self.run()
        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/env"))
        #expect(captures.arguments == ["node", "bin/audit.js"])
        _ = outcome
    }

    @Test func `should run the plugin command from the plugin's own directory`() async throws {
        // Relative paths in `run` resolve against the plugin's files,
        // not against wherever `baguette serve` happened to launch.
        let (_, captures) = await Self.run()
        #expect(captures.workingDirectory?.lastPathComponent == "a11y")
    }

    @Test func `should hand the plugin command the server url, device and token in its environment`() async throws {
        // A plugin talks to the already-warm server rather than
        // re-spawning the ~1.2s baguette binary, so it needs the URL;
        // the token is what the plugin-API routes check.
        let (_, captures) = await Self.run()
        #expect(captures.environment?["BAGUETTE_URL"] == "http://127.0.0.1:8421")
        #expect(captures.environment?["BAGUETTE_UDID"] == "UDID-1")
        #expect(captures.environment?["BAGUETTE_TOKEN"] == "tok-abc")
    }

    @Test func `should leave the device out of the plugin's environment when no simulator is focused`() async throws {
        // Farm-level and device-independent commands run without one.
        // Absent is honest; empty-string would read as a real udid.
        let (_, captures) = await Self.run(udid: nil)
        #expect(captures.environment?["BAGUETTE_UDID"] == nil)
    }

    @Test func `should hand the plugin command its invocation context on stdin`() async throws {
        let (_, captures) = await Self.run()
        let context = try JSONSerialization.jsonObject(
            with: try #require(captures.stdin)
        ) as? [String: Any]
        #expect(context?["command"] as? String == "a11y:audit")
        #expect(context?["udid"] as? String == "UDID-1")
        #expect(context?["url"] as? String == "http://127.0.0.1:8421")
    }

    // MARK: - what comes back

    @Test func `should show the rows the plugin printed when it exits cleanly`() async throws {
        let (outcome, _) = await Self.run(
            stdout: #"{"ok":true,"rows":[{"title":"Button has no label","severity":"error"}]}"#
        )
        guard case .ok(let result) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(result.rows.map(\.title) == ["Button has no label"])
        #expect(result.rows.first?.severity == .error)
    }

    @Test func `should accept a plugin's report of its own failure as a well-formed answer`() async throws {
        // The process did its job and answered honestly. That is not
        // baguette failing to run it, and the user should see the
        // plugin's own words.
        let (outcome, _) = await Self.run(stdout: #"{"ok":false,"message":"Metro is not running"}"#)
        guard case .ok(let result) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(!result.ok)
        #expect(result.message == "Metro is not running")
    }

    @Test func `should reassemble the plugin's output when it arrives in several chunks`() async throws {
        // Pipes split wherever they like; a JSON object cut in half is
        // not a malformed answer.
        let (outcome, _) = await Self.run(stdoutChunks: [#"{"ok":true,"ro"#, #"ws":[{"title":"x"}]}"#])
        guard case .ok(let result) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(result.rows.map(\.title) == ["x"])
    }

    // MARK: - failure paths

    @Test func `should report an unknown command without running anything`() async throws {
        let (outcome, captures) = await Self.run(command: "a11y:nope")
        #expect(outcome == .unknownCommand(id: "a11y:nope"))
        #expect(captures.executable == nil)
    }

    @Test func `should surface the exit status and the plugin's output when it exits non-zero`() async throws {
        let (outcome, _) = await Self.run(
            stdout: "Error: Cannot find module 'bin/audit.js'", exitCode: 1
        )
        #expect(outcome == .exited(status: 1, output: "Error: Cannot find module 'bin/audit.js'"))
    }

    @Test func `should reject plugin output that is not JSON rather than show an empty result`() async throws {
        // An audit panel rendering nothing reads as "no problems
        // found", which is the worst available lie.
        let (outcome, _) = await Self.run(stdout: "Debugger attached.")
        #expect(outcome == .malformedAnswer(PluginResultError.malformedJSON.description))
    }

    @Test func `should report a plugin command that fails to start rather than crash`() async throws {
        let (outcome, _) = await Self.run(spawnThrows: true)
        guard case .spawnFailed = outcome else {
            Issue.record("expected .spawnFailed, got \(outcome)"); return
        }
    }

    // MARK: - helpers

    struct SpawnRefused: Error {}

    // MARK: - a child that won't leave

    /// A child that decides for itself which signal it answers to.
    ///
    /// `run` stores `onExit` rather than calling it, so the child is
    /// still "running" when the deadline lands — which is the whole
    /// situation the timeout exists for.
    final class SignalStubbornChild: Subprocess, @unchecked Sendable {
        /// Whether SIGTERM is enough to end it. `false` models a
        /// program that traps or ignores the polite stop.
        let diesOnTerminate: Bool
        private let lock = NSLock()
        private var onExit: (@Sendable (Int32) -> Void)?
        private(set) var terminated = false
        private(set) var killed = false
        private(set) var grantToken: String?

        init(diesOnTerminate: Bool) { self.diesOnTerminate = diesOnTerminate }

        func run(
            executable: URL, arguments: [String],
            onBytes: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws { store(onExit, environment: [:]) }

        func run(
            executable: URL, arguments: [String], stdin: Data,
            onBytes: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws { store(onExit, environment: [:]) }

        func run(
            executable: URL, arguments: [String], workingDirectory: URL,
            environment: [String: String], stdin: Data,
            onBytes: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws { store(onExit, environment: environment) }

        private func store(
            _ handler: @escaping @Sendable (Int32) -> Void, environment: [String: String]
        ) {
            lock.lock(); defer { lock.unlock() }
            onExit = handler
            grantToken = environment["BAGUETTE_TOKEN"]
        }

        func terminate() {
            lock.lock()
            terminated = true
            let handler = diesOnTerminate ? onExit : nil
            if diesOnTerminate { onExit = nil }
            lock.unlock()
            handler?(15)
        }

        func kill() {
            lock.lock()
            killed = true
            let handler = onExit
            onExit = nil
            lock.unlock()
            handler?(-9)           // SIGKILL can't be trapped
        }
    }

    @Test func `should kill a timed-out plugin command and revoke its grant when it ignores the polite stop`() async throws {
        // `withThrowingTaskGroup` waits for every child task, and the
        // spawn task only finishes when `onExit` fires. Without a
        // signal the child can't refuse, one plugin that traps SIGTERM
        // hangs the route forever.
        let child = SignalStubbornChild(diesOnTerminate: false)
        let (outcome, grants) = await Self.runUntilDeadline(child: child)

        #expect(child.terminated)
        #expect(child.killed)
        guard case .exited(let status, let output) = outcome else {
            Issue.record("expected the timeout outcome, got \(outcome)"); return
        }
        #expect(status == -1)
        #expect(output.contains("timed out"))
        // The whole point of the per-invocation token: it must not
        // outlive the command, however the command ended.
        let token = try #require(child.grantToken)
        #expect(grants.capabilities(for: token) == nil)
    }

    @Test func `should stop a timed-out plugin command politely and revoke its grant when it obeys`() async throws {
        // SIGTERM first, and the grace period is the child's to use for
        // its own cleanup. Escalating immediately would make the polite
        // signal decorative.
        let child = SignalStubbornChild(diesOnTerminate: true)
        let (outcome, grants) = await Self.runUntilDeadline(child: child)

        #expect(child.terminated)
        #expect(child.killed == false)
        // Still reported as a timeout: the child only died because the
        // deadline passed, so "exited on signal 15" would blame the
        // plugin for something the host did.
        guard case .exited(let status, let output) = outcome else {
            Issue.record("expected the timeout outcome, got \(outcome)"); return
        }
        #expect(status == -1)
        #expect(output.contains("timed out"))
        let token = try #require(child.grantToken)
        #expect(grants.capabilities(for: token) == nil)
    }

    static func runUntilDeadline(
        child: any Subprocess
    ) async -> (PluginDispatch.Outcome, PluginGrants) {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(
                root: URL(fileURLWithPath: "/tmp/plugins/a11y"),
                manifest: PluginManifest(
                    name: "a11y", version: "1.0.0", apiVersion: 1,
                    capabilities: [.describeUI],
                    commands: [
                        PluginCommand(id: "audit", title: "Run audit", run: ["node", "bin/audit.js"])
                    ]
                )
            )
        ])
        let grants = PluginGrants()
        let outcome = await PluginDispatch.run(
            qualifiedCommand: "a11y:audit",
            context: PluginDispatch.Context(
                serverURL: "http://127.0.0.1:8421", udid: "UDID-1", token: "tok-abc"
            ),
            plugins: plugins,
            grants: grants,
            timeout: .milliseconds(20),
            grace: .milliseconds(20),
            subprocess: { child }
        )
        return (outcome, grants)
    }

    static func run(
        command: String = "a11y:audit",
        udid: String? = "UDID-1",
        stdout: String = #"{"ok":true}"#,
        stdoutChunks: [String]? = nil,
        exitCode: Int32 = 0,
        spawnThrows: Bool = false
    ) async -> (PluginDispatch.Outcome, Captures) {
        let captures = Captures()
        let sub = MockSubprocess()

        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, cwd, env, stdin, onBytes, onExit in
            if spawnThrows { throw SpawnRefused() }
            captures.executable = exe
            captures.arguments = args
            captures.workingDirectory = cwd
            captures.environment = env
            captures.stdin = stdin
            for chunk in stdoutChunks ?? [stdout] { onBytes(Data(chunk.utf8)) }
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        given(sub).kill().willReturn()

        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(
                root: URL(fileURLWithPath: "/tmp/plugins/a11y"),
                manifest: PluginManifest(
                    name: "a11y", version: "1.0.0", apiVersion: 1,
                    commands: [
                        PluginCommand(id: "audit", title: "Run audit", run: ["node", "bin/audit.js"])
                    ]
                )
            )
        ])

        let outcome = await PluginDispatch.run(
            qualifiedCommand: command,
            context: PluginDispatch.Context(
                serverURL: "http://127.0.0.1:8421", udid: udid, token: "tok-abc"
            ),
            plugins: plugins,
            subprocess: { sub }
        )
        return (outcome, captures)
    }
}
