import Foundation

/// The encoded frames a client has not read yet, held under a byte
/// budget so a slow consumer can never grow the server without bound.
///
/// A stream of independent images values freshness over completeness:
/// once the budget is reached the *oldest* frames go, because what the
/// viewer wants on screen is the newest one. Two frames are never
/// discarded — the newest avcC description, without which a decoder can
/// never start, and the frame that just arrived.
///
/// A reference codec cannot drop that way: every encoded H.264 frame is
/// needed to decode the ones after it, so an AVCC backlog rejects the
/// frame that would overflow its (larger) budget instead, and the owner
/// ends the stream.
///
/// Frames arrive here already stripped of their transport envelope, so
/// an AVCC frame's first byte is its `AVCCEnvelope` tag. A JPEG starts
/// `FFD8`, which is no tag value, so MJPEG frames are all discardable.
/// A metadata packet (`frameMetadata=1`) starts with a length prefix
/// whose first byte is usually zero — the description tag's value — so
/// such a backlog turns description detection off and drops whole
/// packets instead.
struct FrameBacklog {
    /// The most bytes the backlog will hold before it starts discarding.
    /// Deep buffering is actively harmful on a live stream — it buys
    /// latency, not smoothness — so this is deliberately shallow.
    static let defaultByteBudget = 4 * 1024 * 1024

    /// The budget a reference stream may hold before the consumer is
    /// declared too slow: deeper than the discard budget, because the
    /// frames behind a stall are all still needed.
    static let referenceByteBudget = 32 * 1024 * 1024

    let byteBudget: Int
    private let preservingDescriptions: Bool
    private let rejectingOverflow: Bool
    private var frames: [Data] = []
    private(set) var byteCount = 0
    /// How many frames the backlog has discarded over its lifetime, so a
    /// caller can tell a viewer the stream skipped rather than stalled.
    private(set) var droppedCount = 0

    init(
        byteBudget: Int = FrameBacklog.defaultByteBudget, preservingDescriptions: Bool = true,
        rejectingOverflow: Bool = false
    ) {
        self.byteBudget = byteBudget
        self.preservingDescriptions = preservingDescriptions
        self.rejectingOverflow = rejectingOverflow
    }

    /// The policy a format needs: MJPEG discards, AVCC rejects overflow.
    init(format: StreamFormat, preservingDescriptions: Bool = true) {
        self.init(
            byteBudget: format == .avcc ? Self.referenceByteBudget : Self.defaultByteBudget,
            preservingDescriptions: preservingDescriptions, rejectingOverflow: format == .avcc)
    }

    var count: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    /// Appends `frame`, or returns `false` when this backlog rejects
    /// overflow and the frame does not fit: dropping it, or anything
    /// before it, would invalidate every frame that follows.
    @discardableResult
    mutating func append(_ frame: Data) -> Bool {
        if rejectingOverflow, frame.count > byteBudget - byteCount { return false }
        frames.append(frame)
        byteCount += frame.count
        trim()
        return true
    }

    mutating func popFirst() -> Data? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        byteCount -= frame.count
        return frame
    }

    /// Drop from the oldest end until the budget is met, stepping over
    /// the one frame that has to survive. Stops when only the newest
    /// frame (plus the retained description) is left — a single frame
    /// larger than the whole budget is still delivered rather than
    /// silently swallowed.
    ///
    /// Exactly *one* description is ever protected. The encoder rebuilds
    /// its session on a resolution change and emits a fresh description
    /// each time, so protecting every one of them would let a stalled
    /// client hold an unbounded number of them — the budget would stop
    /// being a bound. Only the newest describes the frames still in the
    /// backlog anyway: the ones an earlier description covered are the
    /// first thing trimming takes.
    private mutating func trim() {
        guard byteCount > byteBudget else { return }
        var retained = preservingDescriptions ? frames.lastIndex(where: Self.isDescription) : nil
        var index = 0
        while byteCount > byteBudget, frames.count > 1, index < frames.count - 1 {
            if index == retained {
                index += 1
                continue
            }
            byteCount -= frames[index].count
            frames.remove(at: index)
            droppedCount += 1
            if let retainedIndex = retained, retainedIndex > index {
                retained = retainedIndex - 1
            }
        }
    }

    private static func isDescription(_ frame: Data) -> Bool {
        frame.first == AVCCEnvelope.descriptionTag
    }
}
