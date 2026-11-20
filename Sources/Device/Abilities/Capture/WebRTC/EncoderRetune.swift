import Foundation

/// When a viewer retunes its encoder to the bandwidth estimate: only when the
/// target has moved by more than 10 %, and at most once a second. A
/// VideoToolbox retune isn't free, and the estimate moves every report.
public struct EncoderRetune: Sendable {
    private var lastRetune: Int64?

    public init() {}

    /// The bitrate to retune to now, or nil to leave the encoder alone.
    /// `now` in microseconds.
    public mutating func bitrate(for target: Int, current: Int, now: Int64) -> Int? {
        if let last = lastRetune, now - last < 1_000_000 { return nil }
        guard abs(target - current) * 10 > current else { return nil }
        lastRetune = now
        return target
    }
}
