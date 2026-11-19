import Foundation

/// Where a `Stream` sends its encoded bytes. The CLI writes to stdout;
/// the `serve` HTTP server writes to a WebSocket. Both implement this
/// small output port so the encoder doesn't know or care which it's
/// feeding.
public protocol FrameSink: Sendable {
    /// Append one envelope (or any chunk) to the consumer. Called
    /// from the screen's encode queue; impls must be thread-safe.
    func write(_ data: Data)
    func fail(_ error: any Error)
}
