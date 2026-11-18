import BaguetteDevice
import Foundation
import Mockable

/// A long-running child process that streams stdout bytes and
/// terminates with an exit code. The orchestrator
/// (`SimDeviceLogStream`) uses one to host
/// `xcrun simctl spawn <udid> log stream …`, but the abstraction
/// is generic — anything that needs a piped, terminable child
/// could depend on it.
///
/// The bytes-and-exit shape is deliberately conversational —
/// `run` kicks the child off, `onBytes` fires repeatedly as
/// stdout fills, `onExit` fires once when the child winds down.
/// The orchestrator threads its own state machine through these
/// callbacks; this abstraction just relays the OS-level signals.
///
/// Stderr is pooled with stdout — log binaries that emit
/// `getpwuid_r` warnings or "Filtering the log data using …"
/// banners send those to stderr, and we want them in the same
/// line stream as the actual entries. Callers that need the two
/// separated will need a richer collaborator.
@Mockable
protocol Subprocess: AnyObject, Sendable {
    /// Spawn a child running `executable` with `arguments`.
    /// `onBytes` fires for every chunk that lands on stdout/stderr;
    /// `onExit` fires once when the child winds down, carrying
    /// the wait(2)-style exit status. Both callbacks may run on
    /// arbitrary background queues — implementations are free to
    /// pick whatever queue makes sense for the platform plumbing.
    ///
    /// Throws if the spawn itself fails synchronously (executable
    /// missing, fork failed, etc.). Once `run` returns
    /// successfully the child is live and the implementation
    /// owns its lifetime until either `terminate()` is called or
    /// the child exits on its own.
    func run(
        executable: URL,
        arguments: [String],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit:  @escaping @Sendable (Int32) -> Void
    ) throws

    /// Like `run(executable:arguments:onBytes:onExit:)`, but feeds
    /// `stdin` to the child's standard input and closes it (EOF)
    /// once written. For children that read their payload from
    /// stdin (`simctl pbcopy`). The no-stdin variant keeps the
    /// child detached from the controlling terminal instead —
    /// use it unless the child genuinely consumes stdin.
    func run(
        executable: URL,
        arguments: [String],
        stdin: Data,
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit:  @escaping @Sendable (Int32) -> Void
    ) throws

    /// Like the `stdin` variant, but also pins the child's working
    /// directory and replaces its environment.
    ///
    /// Added for plugin commands, where both are part of the contract
    /// rather than conveniences: `workingDirectory` is the plugin's
    /// own root, so a relative `run` path resolves against the
    /// plugin's files and a plugin cannot reach for the host's cwd;
    /// `environment` is how the invocation context (server URL,
    /// device, per-session token) reaches a child that may be written
    /// in any language.
    ///
    /// `environment` is the child's *complete* environment —
    /// implementations do not merge it with the parent's. Callers that
    /// want the parent's PATH must pass it through explicitly, which
    /// keeps what a plugin inherits an explicit decision.
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        stdin: Data,
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit:  @escaping @Sendable (Int32) -> Void
    ) throws

    /// Send the child the platform's polite-stop signal
    /// (`SIGTERM` on POSIX). Idempotent: repeated calls are
    /// no-ops once the child is already gone or has been asked
    /// to stop. Must be safe to call from any queue.
    /// Like `run(executable:arguments:onBytes:onExit:)`, but keeps the
    /// child's standard input open for `write(_:)` — for a child that
    /// serves commands line by line and lives as long as its owner
    /// (`HingeControl serve`). A conformer that cannot may throw
    /// `SubprocessError.notInteractive`.
    func runInteractive(
        executable: URL,
        arguments: [String],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit:  @escaping @Sendable (Int32) -> Void
    ) throws

    /// Feed bytes to a child started with `runInteractive`.
    func write(_ data: Data) throws

    func terminate()

    /// Send the signal the child cannot trap, ignore or block
    /// (`SIGKILL` on POSIX).
    ///
    /// `terminate()` is a *request*. A child that traps SIGTERM to
    /// finish its work — or one that is wedged in uninterruptible
    /// I/O — never winds down, so `onExit` never fires and whoever
    /// is waiting on this child waits forever. This is the
    /// escalation that guarantees the exit callback arrives, and it
    /// belongs to the caller that set the deadline: only they know
    /// how long the polite signal was worth waiting for.
    ///
    /// Idempotent, safe from any queue, and a no-op once the child
    /// is already gone.
    func kill()
}

enum SubprocessError: Error, Equatable {
    case notInteractive
}

extension Subprocess {
    func runInteractive(
        executable: URL, arguments: [String],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws { throw SubprocessError.notInteractive }

    func write(_ data: Data) throws { throw SubprocessError.notInteractive }
}
