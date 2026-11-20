import Foundation

/// The encoder follows changes over 10 %. Drops apply immediately so it does
/// not outpace the sender. Increases wait a second after the last retune.
public struct EncoderRetune: Sendable {
    private var lastRetune: Int64?

    public init() {}

    /// The bitrate to retune to now, or nil to leave the encoder alone.
    /// `now` in microseconds.
    public mutating func bitrate(for target: Int, current: Int, now: Int64) -> Int? {
        guard abs(target - current) * 10 > current else { return nil }
        if target > current, let last = lastRetune, now - last < 1_000_000 { return nil }
        lastRetune = now
        return target
    }
}
