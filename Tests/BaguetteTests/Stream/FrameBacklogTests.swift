import Testing
import Foundation
@testable import Baguette

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

    @Test func `keeps every frame while under budget`() {
        var backlog = FrameBacklog(byteBudget: 100)
        backlog.append(delta(20))
        backlog.append(delta(30))
        #expect(backlog.count == 2)
        #expect(backlog.byteCount == 50)
        #expect(backlog.droppedCount == 0)
    }

    @Test func `discards the oldest frames once appending would exceed the budget`() {
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

    @Test func `never discards the avcC description a decoder needs to start`() {
        var backlog = FrameBacklog(byteBudget: 100)
        let desc = description(10)
        backlog.append(desc)
        for _ in 0..<8 { backlog.append(delta(40)) }
        #expect(backlog.popFirst() == desc)
        #expect(backlog.byteCount <= 100)
    }

    @Test func `keeps the newest frame even when it alone exceeds the budget`() {
        var backlog = FrameBacklog(byteBudget: 100)
        let huge = delta(500)
        backlog.append(huge)
        #expect(backlog.count == 1)
        #expect(backlog.popFirst() == huge)
    }

    @Test func `drains frames in the order they arrived`() {
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
    @Test func `supersedes an earlier description once the encoder emits a newer one`() {
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

    @Test func `a rotating client cannot grow the backlog with descriptions alone`() {
        var backlog = FrameBacklog(byteBudget: 100)
        for _ in 0..<10_000 { backlog.append(description(40)) }
        #expect(backlog.byteCount <= 100)
    }

    @Test func `a stalled consumer cannot grow the backlog without bound`() {
        var backlog = FrameBacklog(byteBudget: 4096)
        for _ in 0..<10_000 { backlog.append(delta(1024)) }
        #expect(backlog.byteCount <= 4096)
        #expect(backlog.droppedCount > 9_000)
    }
}
