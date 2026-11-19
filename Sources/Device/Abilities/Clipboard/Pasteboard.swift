import Foundation
import Mockable

/// The simulator's shared pasteboard (what iOS exposes as
/// `UIPasteboard.general`). Text goes in and out as plain UTF-8;
/// `syncFromHost` carries the host Mac's full pasteboard across —
/// every representation, images included — which is the path for
/// non-text content.
@Mockable
public protocol Pasteboard: Sendable {
    /// Replace the simulator's pasteboard with plain text.
    func setText(_ text: String) async throws

    /// Read the simulator's pasteboard as plain text.
    func text() async throws -> String

    /// Sync the host Mac's pasteboard onto the simulator,
    /// full-fidelity (all representations, images included).
    func syncFromHost() async throws

    /// Sync the simulator's pasteboard onto the host Mac,
    /// full-fidelity (all representations, images included) — the
    /// mirror of `syncFromHost` and the path for pulling non-text
    /// content the simulator copied back onto the Mac clipboard.
    func syncToHost() async throws
}

/// Failure modes the pasteboard surface reports. The dispatch layer
/// turns these into ack JSON for the caller.
public enum PasteboardError: Error, Equatable, CustomStringConvertible {
    case simctlFailed(status: Int32)

    public var description: String {
        switch self {
        case .simctlFailed(let status):
            return "xcrun simctl pasteboard command exited \(status)"
        }
    }
}
