import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("FrameBacklog")
struct FrameBacklogTests {

    /// AVCC messages reach the backlog as `[tag][payload]`, so a frame's
    /// first byte says what it is. MJPEG frames start `FFD8`, which is
    /// never a tag value.
    /// `marker` makes each frame individually identifiable, so a test can
    /// assert *which* frame survived rather than merely how many did.
    private func frame(_ tag: UInt8, bytes: Int, marker: UInt8 = 0xAA) -> Data {
        Data([tag]) + Data(repeating: marker, count: bytes - 1)
    }
    private func delta(_ bytes: Int, marker: UInt8 = 0xAA) -> Data {
        frame(AVCCEnvelope.deltaTag, bytes: bytes, marker: marker)
    }
    private func description(_ bytes: Int, marker: UInt8 = 0xAA) -> Data {
        frame(AVCCEnvelope.descriptionTag, bytes: bytes, marker: marker)
    }

    private func keyframe(_ bytes: Int, marker: UInt8 = 0xAA) -> Data {
        frame(AVCCEnvelope.keyframeTag, bytes: bytes, marker: marker)
    }

    @Test func `should keep every reference frame and refuse the overflow when the frames can't be read`() {
        // `frameMetadata=1` packets start with a length prefix, not a tag.
        var packets = FrameBacklog(format: .avcc, preservingDescriptions: false)
        let half = Data(repeating: 0x02, count: FrameBacklog.referenceByteBudget / 2)
        #expect(packets.append(half) == .queued)
        #expect(packets.append(half) == .queued)
        #expect(packets.append(Data([0x02])) == .rejected)
        #expect(packets.droppedCount == 0 && packets.count == 2)
    }

    @Test func `should keep only the newest image waiting for an MJPEG viewer`() {
        var jpeg = FrameBacklog(format: .mjpeg)
        let older = Data([0xFF, 0xD8, 1]), newer = Data([0xFF, 0xD8, 2])
        jpeg.append(older)
        jpeg.append(newer)
        #expect(jpeg.count == 1 && jpeg.droppedCount == 1)
        #expect(jpeg.popFirst() == newer)
    }

    // MARK: - a live AVCC viewer skips, it never queues

    @Test func `should send every frame while the viewer keeps up`() {
        var backlog = FrameBacklog(format: .avcc)
        #expect(backlog.append(description(10)) == .queued)
        #expect(backlog.append(keyframe(100)) == .queued)
        for _ in 0..<(FrameBacklog.frameAllowance - 1) {
            #expect(backlog.append(delta(20)) == .queued)
        }
        #expect(backlog.droppedCount == 0)
    }

    @Test func `should drop a delta and ask for a keyframe when the viewer falls the frame allowance behind`() {
        var backlog = FrameBacklog(format: .avcc)
        backlog.append(keyframe(100))
        for _ in 0..<(FrameBacklog.frameAllowance - 1) { backlog.append(delta(20)) }
        #expect(backlog.append(delta(20, marker: 9)) == .droppedAskingForKeyframe)
        #expect(backlog.count == FrameBacklog.frameAllowance)
        #expect(backlog.droppedCount == 1)
    }

    @Test func `should drop later deltas without asking again until a keyframe comes`() {
        var backlog = FrameBacklog(format: .avcc)
        for _ in 0..<FrameBacklog.frameAllowance { backlog.append(delta(20)) }
        backlog.append(delta(20))
        // The viewer catches up, but a delta still has no reference to decode against.
        while backlog.popFirst() != nil {}
        #expect(backlog.append(delta(20)) == .dropped)
        #expect(backlog.append(delta(20)) == .dropped)
        #expect(backlog.append(keyframe(100)) == .queued)
        #expect(backlog.append(delta(20)) == .queued)
    }

    @Test func `should put a keyframe at the front of the queue, keeping the newest description, when it supersedes a backlog`() {
        var backlog = FrameBacklog(format: .avcc)
        backlog.append(description(10, marker: 1))
        backlog.append(keyframe(100, marker: 1))
        for _ in 0..<FrameBacklog.frameAllowance { backlog.append(delta(20)) }
        let current = description(10, marker: 2)
        let fresh = keyframe(100, marker: 2)
        backlog.append(current)
        #expect(backlog.append(fresh) == .queued)
        #expect(backlog.popFirst() == current)
        #expect(backlog.popFirst() == fresh)
        #expect(backlog.popFirst() == nil)
    }

    @Test func `should drop a delta when the viewer falls the byte budget behind`() {
        var backlog = FrameBacklog(format: .avcc)
        backlog.append(keyframe(FrameBacklog.defaultByteBudget))
        #expect(backlog.append(delta(20)) == .droppedAskingForKeyframe)
    }

    @Test func `should keep every frame while the backlog is under budget`() {
        var backlog = FrameBacklog(byteBudget: 100)
        backlog.append(delta(20))
        backlog.append(delta(30))
        #expect(backlog.count == 2)
        #expect(backlog.byteCount == 50)
        #expect(backlog.droppedCount == 0)
    }

    @Test func `should discard the oldest frames when a new frame would exceed the budget`() {
        var backlog = FrameBacklog(byteBudget: 100)
        backlog.append(delta(40, marker: 1))
        backlog.append(delta(40, marker: 2))
        backlog.append(delta(40, marker: 3))
        #expect(backlog.count == 2)
        #expect(backlog.byteCount == 80)
        #expect(backlog.droppedCount == 1)
        // Frame 1 is the one that went; 2 and 3 survive, oldest-first.
        #expect(backlog.popFirst() == delta(40, marker: 2))
        #expect(backlog.popFirst() == delta(40, marker: 3))
    }

    @Test func `should never discard the decoder description a viewer needs to start`() {
        var backlog = FrameBacklog(byteBudget: 100)
        let desc = description(10)
        backlog.append(desc)
        for _ in 0..<8 { backlog.append(delta(40)) }
        #expect(backlog.popFirst() == desc)
        #expect(backlog.byteCount <= 100)
    }

    @Test func `should keep the newest frame even when it alone exceeds the budget`() {
        var backlog = FrameBacklog(byteBudget: 100)
        let huge = delta(500)
        backlog.append(huge)
        #expect(backlog.count == 1)
        #expect(backlog.popFirst() == huge)
    }

    @Test func `should drain frames in the order they arrived`() {
        var backlog = FrameBacklog(byteBudget: 1000)
        let a = delta(10, marker: 1), b = delta(20, marker: 2), c = delta(30, marker: 3)
        backlog.append(a); backlog.append(b); backlog.append(c)
        #expect(backlog.popFirst() == a)
        #expect(backlog.popFirst() == b)
        #expect(backlog.popFirst() == c)
        #expect(backlog.popFirst() == nil)
        #expect(backlog.isEmpty)
    }

    /// The encoder rebuilds its session on every resolution change, and
    /// each rebuild emits a fresh description. Only the last one describes
    /// the frames still in the backlog — the earlier ones describe frames
    /// trimming has already taken, so they stop being worth protecting.
    @Test func `should drop an earlier decoder description when a newer one arrives`() {
        var backlog = FrameBacklog(byteBudget: 100)
        let stale = description(20, marker: 1)
        let current = description(20, marker: 2)
        backlog.append(stale)
        backlog.append(current)
        for _ in 0..<8 { backlog.append(delta(40)) }
        #expect(backlog.byteCount <= 100)

        var survivors: [Data] = []
        while let frame = backlog.popFirst() { survivors.append(frame) }
        #expect(survivors.contains(current))
        // The stale one went with the frames it described.
        #expect(!survivors.contains(stale))
    }

    @Test func `should stay within budget when a rotating client floods it with descriptions`() {
        var backlog = FrameBacklog(byteBudget: 100)
        for _ in 0..<10_000 { backlog.append(description(40)) }
        #expect(backlog.byteCount <= 100)
    }

    @Test func `should stay within budget when the consumer stalls`() {
        var backlog = FrameBacklog(byteBudget: 4096)
        for _ in 0..<10_000 { backlog.append(delta(1024)) }
        #expect(backlog.byteCount <= 4096)
        #expect(backlog.droppedCount > 9_000)
    }
}
