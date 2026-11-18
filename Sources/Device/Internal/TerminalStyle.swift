import BaguetteDevice
import Foundation

/// How a message looks on the way to stderr.
///
/// Pure string composition plus a pure colour decision — the `isatty`
/// probe and the environment lookup stay at the call site in `Logger`,
/// so everything here is unit-covered.
public enum TerminalStyle {
    private static let escape = "\u{001B}"
    /// SGR 33 — plain yellow. Legible on both light and dark terminal
    /// themes, unlike bright yellow, which washes out on white.
    private static let yellow = "\(escape)[33m"
    private static let reset = "\(escape)[0m"

    /// Render a warning.
    ///
    /// The `warning:` marker is applied whether or not colour is on:
    /// colour is the only cue a human gets on a terminal, but a piped
    /// or redirected log has none, so the marker has to survive.
    public static func warning(_ message: String, colored: Bool) -> String {
        let marked = "warning: \(message)"
        guard colored else { return marked }
        // The reset closes the sequence even when the message wraps
        // across lines; leaving it open would tint later output.
        return "\(yellow)\(marked)\(reset)"
    }

    /// Whether to emit colour at all.
    ///
    /// Redirected output stays clean — a log file full of escape
    /// sequences is worse than no colour. `NO_COLOR` (https://no-color.org)
    /// and `TERM=dumb` are both honoured as opt-outs.
    public static func shouldColorize(isTTY: Bool, environment: [String: String]) -> Bool {
        // The convention is explicit that presence alone isn't enough:
        // the value has to be non-empty.
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return false }
        if environment["TERM"] == "dumb" { return false }
        return isTTY
    }
}
