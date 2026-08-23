import Foundation

/// The encoded frames a client has not read yet, held under a byte
/// budget so a slow consumer can never grow the server without bound.
///
/// A live stream values freshness over completeness: once the budget is
/// reached the *oldest* frames go, because what the viewer wants on
/// screen is the newest one. Two frames are never discarded — the avcC
/// description, emitted once and without which a decoder can never
/// start, and the frame that just arrived.
///
/// Frames arrive here already stripped of their transport envelope, so
/// an AVCC frame's first byte is its `AVCCEnvelope` tag. A JPEG starts
/// `FFD8`, which is no tag value, so MJPEG frames are all discardable.
struct FrameBacklog {
    /// The most bytes the backlog will hold before it starts discarding.
    /// Deep buffering is actively harmful on a live stream — it buys
    /// latency, not smoothness — so this is deliberately shallow.
    static let defaultByteBudget = 4 * 1024 * 1024

    let byteBudget: Int
    private var frames: [Data] = []
    private(set) var byteCount = 0
    /// How many frames the backlog has discarded over its lifetime, so a
    /// caller can tell a viewer the stream skipped rather than stalled.
    private(set) var droppedCount = 0

    init(byteBudget: Int = FrameBacklog.defaultByteBudget) {
        self.byteBudget = byteBudget
    }

    var count: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    mutating func append(_ frame: Data) {
        frames.append(frame)
        byteCount += frame.count
        trim()
    }

    mutating func popFirst() -> Data? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        byteCount -= frame.count
        return frame
    }

    /// Drop from the oldest end until the budget is met, stepping over
    /// frames that have to survive. Stops when only the newest frame
    /// (plus any retained ones) is left — a single frame larger than the
    /// whole budget is still delivered rather than silently swallowed.
    private mutating func trim() {
        var index = 0
        while byteCount > byteBudget, frames.count > 1, index < frames.count - 1 {
            if Self.mustRetain(frames[index]) {
                index += 1
                continue
            }
            byteCount -= frames[index].count
            frames.remove(at: index)
            droppedCount += 1
        }
    }

    private static func mustRetain(_ frame: Data) -> Bool {
        frame.first == AVCCEnvelope.descriptionTag
    }
}
