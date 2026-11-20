import Foundation
import Testing
@testable import BaguetteDevice

/// A bottleneck link: packets queue behind each other at `capacity` bits per
/// second, after `latency`; every `lossEvery`th packet is dropped.
private struct Link {
    var capacity: Double
    var latency: Int64 = 20_000
    var lossEvery: Int? = nil
    private var freeAt: Int64 = 0
    private var count = 0

    init(capacity: Double, lossEvery: Int? = nil) {
        self.capacity = capacity
        self.lossEvery = lossEvery
    }

    mutating func carry(sentAt: Int64, size: Int) -> Int64? {
        count += 1
        if let every = lossEvery, count % every == 0 { return nil }
        let start = max(sentAt + latency, freeAt)
        freeAt = start + Int64(Double(size * 8) / capacity * 1_000_000)
        return freeAt
    }
}

/// The viewer and the browser in a loop: every 5 ms the viewer sends what its
/// target allows in 1,200-byte packets; every 100 ms the browser reports.
private func run(_ estimate: inout BandwidthEstimate, over link: inout Link, seconds: Double, from start: Int64 = 0) -> Int64 {
    var now = start
    var sequence: UInt16 = 0
    var batch: [PacketOutcome] = []
    var owed = 0.0
    let end = start + Int64(seconds * 1_000_000)
    while now < end {
        owed += Double(estimate.target) * 0.005 / 8
        while owed >= 1_200 {
            owed -= 1_200
            batch.append(PacketOutcome(sequence: sequence, sentAt: now, size: 1_200, arrivedAt: link.carry(sentAt: now, size: 1_200)))
            sequence &+= 1
        }
        now += 5_000
        if now % 100_000 == 0 {
            // The report covers what has arrived by now, and the drops.
            let (due, later) = (batch.filter { ($0.arrivedAt ?? 0) <= now }, batch.filter { ($0.arrivedAt ?? 0) > now })
            estimate.update(with: due, now: now)
            batch = later
        }
    }
    return now
}

@Suite("BandwidthEstimate")
struct BandwidthEstimateTests {
    @Test func `should keep its starting bitrate on a link with room to spare`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000)

        _ = run(&estimate, over: &link, seconds: 10)

        #expect(estimate.target == 8_000_000)
    }

    @Test func `should settle just under a link slower than it sends`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 2_000_000)

        _ = run(&estimate, over: &link, seconds: 20)

        #expect(estimate.target <= 2_200_000)
        #expect(estimate.target >= 1_000_000)
    }

    @Test func `should climb back once the link frees up`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 2_000_000)
        let later = run(&estimate, over: &link, seconds: 20)

        link.capacity = 50_000_000
        _ = run(&estimate, over: &link, seconds: 40, from: later)

        #expect(estimate.target >= 7_000_000)
    }

    @Test func `should cut its bitrate on a link that loses much of what it sends`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000, lossEvery: 5)   // 20% loss

        _ = run(&estimate, over: &link, seconds: 10)

        #expect(estimate.target <= 4_000_000)
    }

    @Test func `should shrug off a little loss`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000, lossEvery: 100)   // 1% loss

        _ = run(&estimate, over: &link, seconds: 10)

        #expect(estimate.target == 8_000_000)
    }

    @Test func `should never ask for less than its floor`() {
        var estimate = BandwidthEstimate(floor: 300_000, ceiling: 8_000_000)
        var link = Link(capacity: 100_000)

        _ = run(&estimate, over: &link, seconds: 20)

        #expect(estimate.target == 300_000)
    }
}

/// Packets sent every 5 ms; each arrives `queueing(i)` µs later than the one before it would have.
private func groups(_ count: Int, queueing: (Int) -> Int64) -> [PacketOutcome] {
    var arrival: Int64 = 50_000
    return (0..<count).map { i in
        arrival += 5_000 + queueing(i)
        return PacketOutcome(sequence: UInt16(i), sentAt: Int64(i) * 5_000, size: 1_200, arrivedAt: arrival)
    }
}

@Suite("DelayTrend")
struct DelayTrendTests {
    @Test func `should read a link whose delay holds steady as normal`() {
        var trend = DelayTrend()

        for packet in groups(80, queueing: { _ in 0 }) { trend.add(packet) }

        #expect(trend.signal == .normal)
    }

    @Test func `should read a queue that keeps growing as overuse`() {
        var trend = DelayTrend()

        for packet in groups(80, queueing: { _ in 2_000 }) { trend.add(packet) }

        #expect(trend.signal == .overusing)
    }

    @Test func `should read a queue that drains as underuse`() {
        var trend = DelayTrend()

        for packet in groups(80, queueing: { _ in -2_000 }) { trend.add(packet) }

        #expect(trend.signal == .underusing)
    }

    @Test func `should take packets sent within 5 ms of each other as one group`() {
        var trend = DelayTrend()
        let burst = (0..<10).map { PacketOutcome(sequence: UInt16($0), sentAt: 1_000 + Int64($0) * 100, size: 1_200, arrivedAt: 60_000 + Int64($0) * 1_000) }

        for packet in burst { trend.add(packet) }

        #expect(trend.groupsSeen == 1)
    }
}
