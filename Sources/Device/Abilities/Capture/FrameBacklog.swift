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
/// A reference codec cannot drop that way: every encoded H.264 / HEVC
/// delta needs the one before it. So a live AVCC viewer *skips* instead
/// (docs/features/stream/design.md): past `frameAllowance` frames or the
/// byte budget a delta is dropped, every later delta with it, until a
/// keyframe — which is never dropped and supersedes everything queued in
/// front of it but the newest description. The owner asks the stream for
/// that keyframe when `append` says so.
///
/// Packets the backlog can't read (below) keep every frame instead, and
/// reject the frame that would overflow `referenceByteBudget`; the owner
/// then ends the stream.
///
/// Frames arrive here already stripped of their transport envelope, so
/// an AVCC frame's first byte is its `AVCCEnvelope` tag. A JPEG starts
/// `FFD8`, which is no tag value, so MJPEG frames are all discardable.
/// A metadata packet (`frameMetadata=1`) starts with a length prefix
/// whose first byte is usually zero — the description tag's value — so
/// such a backlog turns description detection off and drops whole
/// packets instead.
public struct FrameBacklog {
    /// The most bytes the backlog will hold before it starts discarding.
    /// Deep buffering is actively harmful on a live stream — it buys
    /// latency, not smoothness — so this is deliberately shallow.
    public static let defaultByteBudget = 4 * 1024 * 1024

    /// The budget a reference stream may hold before the consumer is
    /// declared too slow: deeper than the discard budget, because the
    /// frames behind a stall are all still needed.
    public static let referenceByteBudget = 32 * 1024 * 1024

    /// The most encoded frames a live AVCC viewer may have waiting before
    /// the next delta is dropped: 100 ms at 60 fps, room for a keyframe
    /// crossing the link and the deltas behind it.
    public static let frameAllowance = 6

    /// What became of a frame handed to `append`.
    public enum Admission: Equatable, Sendable {
        case queued
        /// Dropped; the viewer already waits for a keyframe.
        case dropped
        /// Dropped, and the viewer now waits for a keyframe: ask the stream for one.
        case droppedAskingForKeyframe
        /// Refused: the stream can't go on for this viewer.
        case rejected
    }

    private enum Policy { case discardOldest, skipToKeyframe, rejectOverflow }

    public let byteBudget: Int
    private let preservingDescriptions: Bool
    private let policy: Policy
    /// The most frames kept waiting, newest first; nil keeps what the budget allows.
    private var frameCap: Int?
    private var awaitingKeyframe = false
    private var frames: [Data] = []
    public private(set) var byteCount = 0
    /// How many frames the backlog has discarded over its lifetime, so a
    /// caller can tell a viewer the stream skipped rather than stalled.
    public private(set) var droppedCount = 0

    public init(
        byteBudget: Int = FrameBacklog.defaultByteBudget, preservingDescriptions: Bool = true,
        rejectingOverflow: Bool = false
    ) {
        self.byteBudget = byteBudget
        self.preservingDescriptions = preservingDescriptions
        self.policy = rejectingOverflow ? .rejectOverflow : .discardOldest
    }

    private init(byteBudget: Int, policy: Policy) {
        self.byteBudget = byteBudget
        self.preservingDescriptions = true
        self.policy = policy
    }

    /// The policy a format needs: MJPEG discards its oldest images, a
    /// readable AVCC stream skips to the next keyframe, and AVCC packets
    /// (`preservingDescriptions` off) reject overflow.
    public init(format: StreamFormat, preservingDescriptions: Bool = true) {
        switch (format, preservingDescriptions) {
        case (.mjpeg, _):
            // Every image is whole: a viewer wants the newest, never a queue of them.
            self.init(byteBudget: Self.defaultByteBudget, preservingDescriptions: preservingDescriptions)
            frameCap = 1
        case (.avcc, true):
            self.init(byteBudget: Self.defaultByteBudget, policy: .skipToKeyframe)
        case (.avcc, false):
            self.init(byteBudget: Self.referenceByteBudget, preservingDescriptions: false, rejectingOverflow: true)
        }
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    /// Appends `frame`, or says why it didn't.
    @discardableResult
    public mutating func append(_ frame: Data) -> Admission {
        switch policy {
        case .rejectOverflow:
            guard frame.count <= byteBudget - byteCount else { return .rejected }
        case .skipToKeyframe:
            switch frame.first {
            case AVCCEnvelope.keyframeTag:
                supersede()
                awaitingKeyframe = false
            case AVCCEnvelope.deltaTag:
                if awaitingKeyframe {
                    droppedCount += 1
                    return .dropped
                }
                if encodedFramesWaiting >= Self.frameAllowance || frame.count > byteBudget - byteCount {
                    droppedCount += 1
                    awaitingKeyframe = true
                    return .droppedAskingForKeyframe
                }
            default:
                break
            }
        case .discardOldest:
            break
        }
        frames.append(frame)
        byteCount += frame.count
        if policy == .discardOldest { trim() }
        if let frameCap {
            while frames.count > frameCap {
                byteCount -= frames.removeFirst().count
                droppedCount += 1
            }
        }
        return .queued
    }

    /// Keyframes and deltas waiting; descriptions and seeds don't count.
    private var encodedFramesWaiting: Int {
        frames.count { $0.first == AVCCEnvelope.keyframeTag || $0.first == AVCCEnvelope.deltaTag }
    }

    /// A keyframe decodes on its own: everything queued in front of it is
    /// stale but the newest description, which the keyframe may need.
    private mutating func supersede() {
        let kept = frames.last(where: Self.isDescription)
        droppedCount += frames.count - (kept == nil ? 0 : 1)
        frames = kept.map { [$0] } ?? []
        byteCount = kept?.count ?? 0
    }

    public mutating func popFirst() -> Data? {
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
