import Foundation
import Mockable

/// Live unified-log feed for one booted simulator. One verb to start
/// and one to stop, with line-oriented delivery. Mirrors `Screen`'s
/// shape (`start(onFrame:)` / `stop()`), in text instead of frames.
///
/// `start` may throw if the underlying spawn fails synchronously
/// (simulator not booted, missing `/usr/bin/log`, etc.). `onLine`
/// fires once per emitted log line; `onTerminate` fires once when
/// the spawned process exits — naturally on `stop()`, with a
/// non-nil error when the simulator died or the spawn returned an
/// error code. Callbacks may run on the adapter's own dispatch
/// queue; consumers that touch UI state should hop themselves.
@Mockable
protocol LogStream: AnyObject, Sendable {
    func start(
        filter: LogFilter,
        onLine: @escaping @Sendable (String) -> Void,
        onTerminate: @escaping @Sendable (Error?) -> Void
    ) throws

    /// Tear down: SIGTERM the spawned process, drain the pipe, fire
    /// `onTerminate(nil)`. Idempotent — calling stop on an already
    /// stopped stream is a no-op.
    func stop()
}

/// Failure modes the log adapter surfaces. Each maps to a clean
/// CLI exit message / WS error envelope.
enum LogStreamError: Error, Equatable {
    case simulatorNotBooted(udid: String)
    case spawnFailed(reason: String)
    case alreadyStarted
    case nonZeroExit(code: Int32)
}
