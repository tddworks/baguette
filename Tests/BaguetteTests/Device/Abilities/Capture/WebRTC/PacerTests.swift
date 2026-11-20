import Foundation
import Testing
@testable import BaguetteDevice

/// 1,200-byte packets, as a frame is cut; times in microseconds.
private func frame(_ packets: Int, into pacer: inout Pacer<Int>, at now: Int64, from first: Int = 0) {
    for i in first..<(first + packets) { pacer.enqueue(i, size: 1_200, at: now) }
}

@Suite("Pacer")
struct PacerTests {
    @Test func `should send a small frame at once`() {
        var pacer = Pacer<Int>(bitrate: 8_000_000)

        frame(3, into: &pacer, at: 0)

        #expect(pacer.release(at: 0) == [0, 1, 2])
        #expect(pacer.isEmpty)
    }

    @Test func `should spread a keyframe's packets at two and a half times its bitrate`() {
        var pacer = Pacer<Int>(bitrate: 8_000_000)   // paced at 20 Mbps: 1,200 bytes every 0.48 ms
        frame(60, into: &pacer, at: 0)

        var sentBy: [Int64: Int] = [:]
        var sent = 0
        for now in stride(from: Int64(0), through: 40_000, by: 5_000) {
            sent += pacer.release(at: now).count
            sentBy[now] = sent
        }

        #expect(sentBy[0]! < 15)                 // not all at once
        #expect(sentBy[10_000]! < 40)
        #expect(sentBy[30_000]! == 60)           // all gone in ~29 ms
    }

    @Test func `should not save up the time it sat idle`() {
        var pacer = Pacer<Int>(bitrate: 8_000_000)
        frame(1, into: &pacer, at: 0)
        _ = pacer.release(at: 0)

        frame(60, into: &pacer, at: 1_000_000, from: 1)

        #expect(pacer.release(at: 1_000_000).count < 15)
    }

    @Test func `should follow a new bitrate`() {
        var pacer = Pacer<Int>(bitrate: 8_000_000)
        pacer.bitrate = 2_000_000                // paced at 5 Mbps: ~1.9 ms a packet
        frame(60, into: &pacer, at: 0)

        var sent = pacer.release(at: 0).count
        sent += pacer.release(at: 10_000).count

        #expect(sent < 10)
    }

    @Test func `should send faster than its bitrate rather than hold more than half a second of video`() {
        var pacer = Pacer<Int>(bitrate: 300_000)   // 750 kbps paced: 60 packets would take 768 ms
        frame(60, into: &pacer, at: 0)

        var sent = 0
        for now in stride(from: Int64(0), through: 500_000, by: 5_000) { sent += pacer.release(at: now).count }

        #expect(sent == 60)
    }

    @Test func `should send every packet at once when it isn't pacing`() {
        var pacer = Pacer<Int>(bitrate: 8_000_000, pacing: false)
        frame(60, into: &pacer, at: 0)

        #expect(pacer.release(at: 0) == Array(0..<60))
    }

    @Test func `should tell how long its oldest packet has waited, and nothing when empty`() {
        var pacer = Pacer<Int>(bitrate: 300_000)
        #expect(pacer.oldestWait(at: 0) == nil)

        frame(60, into: &pacer, at: 1_000)
        _ = pacer.release(at: 1_000)

        #expect(pacer.oldestWait(at: 81_000) == 80_000)
    }

    @Test func `should keep the order packets came in`() {
        var pacer = Pacer<Int>(bitrate: 8_000_000)
        frame(60, into: &pacer, at: 0)

        var order: [Int] = []
        for now in stride(from: Int64(0), through: 40_000, by: 5_000) { order += pacer.release(at: now) }

        #expect(order == Array(0..<60))
    }
}
