import Foundation

/// Where a `Stream` sends its encoded bytes. The CLI writes to stdout;
/// the `serve` HTTP server writes to a WebSocket. Both implement this
/// one-method port so the encoder doesn't know or care which it's
/// feeding.
protocol FrameSink: Sendable {
    /// Append one envelope (or any chunk) to the consumer. Called
    /// from the screen's encode queue; impls must be thread-safe.
    func write(_ data: Data)
}

/// CLI sink — `baguette stream` writes binary frames to stdout. The
/// encoders run on the screen's own queue and may overlap with the
/// keepalive / reconfig timers, so every `write` is serialised by an
/// `NSLock`.
final class StdoutSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private let handle = FileHandle.standardOutput

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        handle.write(data)
    }
}
