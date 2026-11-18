import Foundation

/// The terminal a command runs in, beyond its arguments and its words: the
/// lines piped to its stdin, and the Ctrl-C (or SIGTERM) that ends a long
/// run. Injected so a command that reads stdin or waits to be stopped can
/// be run in a test.
struct Terminal: Sendable {
    /// The next line on stdin, without its newline; nil once stdin ends.
    let readLine: @Sendable () -> String?
    /// Everything on stdin, to its end.
    let readAll: @Sendable () -> Data
    /// Call `handler` when one of `signals` arrives instead of dying of it.
    /// Returns what puts those signals back to their default.
    let onInterrupt: @Sendable (_ signals: [Int32], _ handler: @escaping @Sendable () -> Void) -> Restore

    /// Puts interrupted signals back to their default.
    typealias Restore = @Sendable () -> Void

    init(
        readLine: @escaping @Sendable () -> String?,
        readAll: @escaping @Sendable () -> Data,
        onInterrupt: @escaping @Sendable ([Int32], @escaping @Sendable () -> Void) -> Restore
    ) {
        self.readLine = readLine
        self.readAll = readAll
        self.onInterrupt = onInterrupt
    }

    /// This run's terminal: the process's own, unless a test stands in.
    @TaskLocal static var current: Terminal = .standard
}
