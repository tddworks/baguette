import Foundation

/// Single-line stderr log. Stdout is reserved for stream output / acks;
/// every other message goes here so it doesn't corrupt the wire.
func log(_ message: String) {
    fputs("[baguette] \(message)\n", stderr)
}

/// Routine progress, for someone debugging baguette: which symbols resolved, each
/// key sent. Off by default, because an agent's shell reads stderr too, and every
/// line costs it. Failures stay on `log`, so they always print.
func trace(_ message: String) {
    guard Trace.enabled else { return }
    log(message)
}

enum Trace {
    static let variable = "BAGUETTE_VERBOSE"

    /// Read once, so a per-key call stays cheap. `baguette serve` sets the variable
    /// before anything traces, so its log stays as it was.
    private static let enabled_ = isOn(environment: ProcessInfo.processInfo.environment)
    fileprivate static var enabled: Bool { enabled_ }

    static func isOn(environment: [String: String]) -> Bool {
        guard let value = environment[variable], !value.isEmpty else { return false }
        return value != "0"
    }
}

/// Like `log`, but marked as a warning — tinted yellow when stderr is a
/// terminal, plain (and still marked) when it's redirected.
func warn(_ message: String) {
    let styled = TerminalStyle.warning(message, colored: terminalColorized(STDERR_FILENO))
    fputs("[baguette] \(styled)\n", stderr)
}

/// Whether the given file descriptor should carry ANSI colour.
///
/// The `isatty` probe and the environment read are the only impure
/// parts; the decision itself lives in `TerminalStyle` and is covered.
func terminalColorized(_ fileDescriptor: Int32) -> Bool {
    TerminalStyle.shouldColorize(
        isTTY: isatty(fileDescriptor) == 1,
        environment: ProcessInfo.processInfo.environment
    )
}
