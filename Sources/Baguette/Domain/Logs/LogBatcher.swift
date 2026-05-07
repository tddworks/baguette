import Foundation

/// Coalesces individual log lines into bounded batches. The browser
/// pays a per-WS-frame cost (parse, dispatch, render) that's flat
/// regardless of payload size, so emitting one frame per line at
/// CoreDuet-chatter rates (hundreds/sec) saturates the main thread
/// long before bandwidth becomes the issue. Batching to one frame
/// per ~50 ms drops that to ~20 frames/sec and decouples log volume
/// from UI responsiveness.
///
/// Pure value-domain — no clock, no I/O. The caller supplies `now`
/// on every entry so tests are deterministic and the production
/// caller can use `Date()` from its own scheduler tick.
///
/// Window contract: a window opens on the first ingested line. Any
/// drain (size-cap, time-cap, explicit `flush`) closes the window;
/// the next ingest starts a fresh one. Calls to `tick` / `flush`
/// against an empty buffer return `nil`.
struct LogBatcher {
    let maxLines: Int
    let windowMs: Int

    private var buffer: [String] = []
    private var windowStart: Date?

    init(maxLines: Int = 200, windowMs: Int = 50) {
        self.maxLines = maxLines
        self.windowMs = windowMs
    }

    /// Append `line` to the open window. Returns the drained batch
    /// when the size cap is reached, otherwise `nil`.
    mutating func ingest(_ line: String, now: Date) -> [String]? {
        if windowStart == nil { windowStart = now }
        buffer.append(line)
        if buffer.count >= maxLines { return drain() }
        return nil
    }

    /// If a window is open and `now - windowStart >= windowMs`,
    /// drain and return the batch. Otherwise `nil`. Comparison is
    /// rounded to whole milliseconds so the threshold isn't tripped
    /// by floating-point cancellation when callers derive `now` via
    /// `Date.addingTimeInterval` against a far-off reference.
    mutating func tick(now: Date) -> [String]? {
        guard let start = windowStart else { return nil }
        let elapsedMs = Int((now.timeIntervalSince(start) * 1000.0).rounded())
        guard elapsedMs >= windowMs else { return nil }
        return drain()
    }

    /// Drain whatever's accumulated regardless of window state.
    /// Returns `nil` if the buffer is empty.
    mutating func flush() -> [String]? {
        guard !buffer.isEmpty else { return nil }
        return drain()
    }

    private mutating func drain() -> [String] {
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        windowStart = nil
        return out
    }
}
