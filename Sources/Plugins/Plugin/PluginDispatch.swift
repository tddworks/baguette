import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// Runs one contributed plugin command and turns what the child said
/// into an outcome the CLI and the serve route can both project.
/// Sits alongside `GestureDispatcher` / `CopyDispatch` / `PasteDispatch`
/// as the App-layer orchestration for one entry point.
///
/// The whole execution model in one place: a command is an argv the
/// manifest declared, spawned **only** when the user activates it,
/// inside the plugin's own directory, with a fresh environment
/// carrying the invocation context. It answers with one JSON object on
/// stdout. Nothing about a plugin runs at scan time, and nothing a
/// plugin ships is ever loaded into baguette's own process or page.
enum PluginDispatch {

    /// What the plugin needs to know to talk back to the server it was
    /// launched from.
    struct Context: Equatable, Sendable {
        /// Origin of the already-warm server. Plugins call this rather
        /// than re-spawning the `baguette` binary, which costs ~1.2s in
        /// framework resolution alone.
        let serverURL: String
        /// The focused device, when there is one. Farm-level and
        /// device-independent commands run without.
        let udid: String?
        /// Per-session token the plugin-API routes check.
        let token: String
        /// Arguments from the row that invoked this command, when one
        /// did. Absent for a panel simply being opened, which is every
        /// invocation that predates `rowAction: "run"`.
        let args: PluginArgs?

        init(serverURL: String, udid: String?, token: String, args: [String: Any]? = nil) {
            self.serverURL = serverURL
            self.udid = udid
            self.token = token
            self.args = args.flatMap(PluginArgs.init)
        }

        private init(serverURL: String, udid: String?, token: String, args: PluginArgs?) {
            self.serverURL = serverURL
            self.udid = udid
            self.token = token
            self.args = args
        }

        /// The same context re-issued with a per-invocation grant token.
        ///
        /// A copy rather than a rebuild on purpose: spelling the fields
        /// out at the call site is how `args` got dropped on the way to
        /// the plugin the first time, and any field added later would
        /// have been dropped the same way.
        func withToken(_ token: String) -> Context {
            Context(serverURL: serverURL, udid: udid, token: token, args: args)
        }
    }

    enum Outcome: Equatable {
        /// The plugin answered in the agreed shape. Note this covers
        /// `ok: false` too — a plugin reporting honestly that its job
        /// failed held up its end of the contract, and the user should
        /// see the plugin's own message rather than one we invented.
        case ok(PluginResult)
        /// No installed plugin contributes this namespaced id.
        case unknownCommand(id: String)
        /// The child never started (missing interpreter, bad perms).
        case spawnFailed(String)
        /// The child ran and failed. `output` is whatever it printed —
        /// stdout and stderr are pooled, so this is usually the stack
        /// trace the author needs.
        case exited(status: Int32, output: String)
        /// The child exited cleanly but didn't answer in the agreed
        /// shape. Deliberately not folded into an empty result: a
        /// panel rendering nothing reads as "all clear".
        case malformedAnswer(String)

        /// One `{"ok":…}` line, matching the `GestureDispatcher` ack
        /// contract used by `baguette input` and the CLI.
        var ackJSON: String {
            switch self {
            case .ok(let result) where result.ok:
                return #"{"ok":true}"#
            case .ok(let result):
                let message = result.message ?? "plugin reported failure"
                return "{\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(message))\"}"
            default:
                return "{\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(errorText ?? ""))\"}"
            }
        }

        /// Human-readable failure, or nil when the plugin answered.
        var errorText: String? {
            switch self {
            case .ok: return nil
            case .unknownCommand(let id): return "no installed plugin contributes \"\(id)\""
            case .spawnFailed(let reason): return "plugin failed to start: \(reason)"
            case .exited(let status, let output):
                let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return tail.isEmpty
                    ? "plugin exited \(status)"
                    : "plugin exited \(status): \(tail)"
            case .malformedAnswer(let reason): return "plugin answered badly: \(reason)"
            }
        }
    }

    /// How long a command may run before it's terminated. A plugin
    /// button that never returns is indistinguishable from a hung UI,
    /// so the host bounds it rather than trusting authors to.
    static let timeout: Duration = .seconds(10)

    /// How long a command gets between the polite stop and the signal
    /// it can't refuse. Long enough for a well-written child to flush
    /// and clean up after itself; short enough that a route waiting on
    /// a wedged plugin still answers.
    static let grace: Duration = .seconds(2)

    /// Resolve `qualifiedCommand` (`a11y:audit`) against the installed
    /// plugins and run it.
    ///
    /// When `grants` is supplied, the invocation gets its own token
    /// carrying exactly the plugin's declared capabilities, revoked the
    /// moment the command finishes. That token — not a shared session
    /// secret — is what the plugin API checks, so a plugin can only do
    /// what its manifest asked for.
    static func run(
        qualifiedCommand: String,
        context: Context,
        plugins: any Plugins,
        grants: PluginGrants? = nil,
        timeout: Duration = PluginDispatch.timeout,
        grace: Duration = PluginDispatch.grace,
        subprocess: @Sendable () -> any Subprocess = { HostSubprocess() }
    ) async -> Outcome {
        guard let (plugin, command) = (try? plugins.resolve(qualifiedCommand: qualifiedCommand)) ?? nil
        else {
            return .unknownCommand(id: qualifiedCommand)
        }

        // Least privilege, scoped to this one run: the child gets a
        // token carrying exactly what the manifest declared, revoked
        // the moment the command returns.
        let issuedToken = grants?.issue(
            plugin: plugin.id, capabilities: plugin.manifest.capabilities
        )
        let runContext = issuedToken.map { context.withToken($0) } ?? context
        defer { if let issuedToken { grants?.revoke(issuedToken) } }

        let child = subprocess()
        let collected = Collected()
        let deadline = Deadline()

        do {
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        do {
                            try child.run(
                                executable: Self.env,
                                // The argv goes to `/usr/bin/env`, which does the
                                // PATH lookup — a plugin says ["node", …] without
                                // needing to know where the user's node lives.
                                arguments: command.run,
                                workingDirectory: plugin.root,
                                environment: environment(for: runContext),
                                stdin: contextJSON(qualifiedCommand, runContext),
                                onBytes: { collected.append($0) },
                                onExit: { status in
                                    deadline.noteChildLeft()
                                    // A child that died *because* the
                                    // deadline passed is a timeout, not
                                    // a plugin that chose to exit on
                                    // signal 15 — blaming the plugin
                                    // would send its author hunting.
                                    continuation.resume(
                                        returning: deadline.hasPassed
                                            ? Self.timedOut(after: timeout)
                                            : finish(status: status, collected: collected)
                                    )
                                }
                            )
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                group.addTask {
                    // A cancelled sleep means the child answered first.
                    // `group.next()` has already taken that outcome, so
                    // this task's return value is discarded — there is
                    // nothing left to signal or report.
                    guard (try? await Task.sleep(for: timeout)) != nil else {
                        return Self.timedOut(after: timeout)
                    }
                    deadline.pass()
                    child.terminate()
                    // SIGTERM is a request the child may trap or
                    // ignore. If it does, its exit handler never fires
                    // — so the spawn task's continuation never resumes,
                    // this group never returns, and the per-invocation
                    // capability grant stays live for as long as the
                    // child feels like running. The grace period is the
                    // child's to clean up in; after it comes the signal
                    // it cannot refuse.
                    try? await Task.sleep(for: grace)
                    if !deadline.childHasLeft { child.kill() }
                    return Self.timedOut(after: timeout)
                }

                // Whichever finishes first wins; the loser is cancelled.
                // Via `defer` so a spawn that throws cancels the timer
                // too, rather than leaning on the group's own unwind.
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            return .spawnFailed("\(error)")
        }
    }

    // MARK: - private

    private static let env = URL(fileURLWithPath: "/usr/bin/env")

    /// Accumulates stdout across however many chunks the pipe decides
    /// to deliver. A JSON object split across two reads is not a
    /// malformed answer.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(bytes)
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    private static func timedOut(after timeout: Duration) -> Outcome {
        .exited(status: -1, output: "timed out after \(timeout)")
    }

    /// Who reached the finish line first — the clock, or the child.
    ///
    /// Both flags are written from the timeout task and read from the
    /// child's exit callback (and the other way round), on whatever
    /// queues the platform picked, so both go through the lock.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var passed = false
        private var childLeft = false

        /// Latch the deadline, so the exit callback reports a timeout
        /// rather than whatever signal happened to end the child.
        func pass() {
            lock.lock(); defer { lock.unlock() }
            passed = true
        }

        var hasPassed: Bool {
            lock.lock(); defer { lock.unlock() }
            return passed
        }

        /// Latch the child's exit, so escalation stops at the polite
        /// signal when the polite signal was enough.
        func noteChildLeft() {
            lock.lock(); defer { lock.unlock() }
            childLeft = true
        }

        var childHasLeft: Bool {
            lock.lock(); defer { lock.unlock() }
            return childLeft
        }
    }

    private static func finish(status: Int32, collected: Collected) -> Outcome {
        let output = collected.value
        guard status == 0 else {
            return .exited(
                status: status,
                output: String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        do {
            return .ok(try PluginResult.parsing(json: output))
        } catch {
            return .malformedAnswer("\(error)")
        }
    }

    /// The child's complete environment. `PATH` is forwarded so
    /// `/usr/bin/env` can find the interpreter; nothing else of the
    /// host's is passed through, so what a plugin inherits stays an
    /// explicit decision rather than an accident.
    private static func environment(for context: Context) -> [String: String] {
        var env: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "BAGUETTE_URL": context.serverURL,
            "BAGUETTE_TOKEN": context.token,
        ]
        // Absent rather than empty when nothing is focused — an empty
        // string would read as a real udid to a naive plugin.
        if let udid = context.udid { env["BAGUETTE_UDID"] = udid }
        return env
    }

    /// Same context as the environment, in structured form, for
    /// plugins that would rather read stdin than `process.env`.
    ///
    /// `args` ride this channel rather than the environment: env values
    /// are strings, so a nested object would have to be flattened and
    /// the plugin would parse back what it just sent. Absent entirely
    /// when there are none, so a command written before `rowAction:
    /// "run"` existed sees exactly the context it always did.
    static func contextJSON(_ qualifiedCommand: String, _ context: Context) -> Data {
        var dict: [String: Any] = [
            "command": qualifiedCommand,
            "url": context.serverURL,
            "token": context.token,
        ]
        if let udid = context.udid { dict["udid"] = udid }
        if let args = context.args { dict["args"] = args.object }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }
}
