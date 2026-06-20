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

    /// Send the child the platform's polite-stop signal
    /// (`SIGTERM` on POSIX). Idempotent: repeated calls are
    /// no-ops once the child is already gone or has been asked
    /// to stop. Must be safe to call from any queue.
    func terminate()
}
