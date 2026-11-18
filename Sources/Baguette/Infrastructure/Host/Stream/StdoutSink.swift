import Foundation

/// Where a `Stream` sends its encoded bytes. The CLI writes to stdout;
/// the `serve` HTTP server writes to a WebSocket. Both implement this
/// small output port so the encoder doesn't know or care which it's
/// feeding.
protocol FrameSink: Sendable {
    /// Append one envelope (or any chunk) to the consumer. Called
    /// from the screen's encode queue; impls must be thread-safe.
    func write(_ data: Data)
    func fail(_ error: any Error)
}

/// CLI sink — `baguette stream` writes binary frames to stdout. The
/// encoders run on the screen's own queue and may overlap with the
/// keepalive / reconfig timers, so every `write` is serialised by an
/// `NSLock`.
final class StdoutSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private let handle = FileHandle.standardOutput
    private let onFailure: @Sendable (any Error) -> Void
    private var failed = false

    init(onFailure: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.onFailure = onFailure
    }

    func fail(_ error: any Error) {
        let firstFailure = lock.withLock {
            guard !failed else { return false }
            failed = true
            return true
        }
        guard firstFailure else { return }
        log("stream failed: \(error)")
        onFailure(error)
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return }
        handle.write(data)
    }
}
