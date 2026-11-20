import Foundation
import Testing
@testable import WebRTCKit

/// A bottleneck link: packets queue behind each other at `capacity` bits per
/// second, after `latency`; every `lossEvery`th packet is dropped.
private struct Link {
    var capacity: Double
    var latency: Int64 = 20_000
    var lossEvery: Int? = nil
    var peakQueueDelay: Int64 = 0
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
        peakQueueDelay = max(peakQueueDelay, start - sentAt - latency)
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

    @Test func `should settle near a 5 Mbps bottleneck without rebuilding a 100 ms queue`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 5_000_000)
        let warmed = run(&estimate, over: &link, seconds: 4)

        link.peakQueueDelay = 0
        _ = run(&estimate, over: &link, seconds: 25, from: warmed)

        #expect((4_000_000...5_500_000).contains(estimate.target))
        #expect(link.peakQueueDelay < 100_000)
    }

    @Test func `should quickly regain bitrate after an isolated delay spike`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000)
        let steady = run(&estimate, over: &link, seconds: 2)

        link.latency += 80_000
        let delayed = run(&estimate, over: &link, seconds: 0.4, from: steady)
        #expect(estimate.target < 7_500_000)

        link.latency -= 80_000
        _ = run(&estimate, over: &link, seconds: 2, from: delayed)

        #expect(estimate.target >= 7_500_000)
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

    @Test func `should say a cut came from the queue growing, and by how much`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 2_000_000)

        _ = run(&estimate, over: &link, seconds: 5)

        guard case .queue(let delay)? = estimate.lastCut?.cause else {
            Issue.record("no queue cut: \(String(describing: estimate.lastCut))")
            return
        }
        #expect(delay >= 40_000)
    }

    @Test func `should say a cut came from loss, and how much was lost`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000, lossEvery: 5)   // 20% loss

        _ = run(&estimate, over: &link, seconds: 10)

        guard case .loss(let fraction)? = estimate.lastCut?.cause else {
            Issue.record("no loss cut: \(String(describing: estimate.lastCut))")
            return
        }
        #expect(abs(fraction - 0.2) < 0.05)
    }

    @Test func `should attribute a bitrate cut to the tighter limit when queue delay and loss rise together`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        let steady = reports(60, extra: { _ in 0 }).flatMap { $0 }
        estimate.update(with: steady, now: 350_000)

        let congested = reports(60, from: 60, extra: { _ in 65_000 }).flatMap { $0 }.map { packet in
            PacketOutcome(sequence: packet.sequence, sentAt: packet.sentAt, size: packet.size,
                          arrivedAt: packet.sequence.isMultiple(of: 5) ? nil : packet.arrivedAt)
        }
        estimate.update(with: congested, now: 750_000)

        #expect(estimate.target < 7_200_000)
        #expect(estimate.lastCut?.to == estimate.target)
        #expect(estimate.lastCut?.cause == .queue(delay: 65_000))
    }

    @Test func `should keep the last cut when loss cannot lower the bitrate past its floor`() {
        var estimate = BandwidthEstimate(ceiling: 1_200_000)
        let lost = (0..<20).map { PacketOutcome(sequence: UInt16($0), sentAt: Int64($0) * 5_000,
                                                size: 1_200, arrivedAt: nil) }
        estimate.update(with: lost, now: 600_000)
        estimate.update(with: lost, now: 1_200_000)
        let floorCut = estimate.lastCut

        estimate.update(with: lost, now: 1_800_000)

        #expect(floorCut?.to == 300_000)
        #expect(estimate.target == 300_000)
        #expect(estimate.lastCut == floorCut)
    }

    @Test func `should have made no cut on a link with room to spare`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000)

        _ = run(&estimate, over: &link, seconds: 10)

        #expect(estimate.lastCut == nil)
    }

    @Test func `should shrug off a little loss`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000, lossEvery: 100)   // 1% loss

        _ = run(&estimate, over: &link, seconds: 10)

        #expect(estimate.target == 8_000_000)
    }

    @Test func `should keep its bitrate while a still screen sends far less than it allows`() {
        var estimate = BandwidthEstimate(ceiling: 8_000_000)
        var link = Link(capacity: 50_000_000)
        var now: Int64 = 0
        var sequence: UInt16 = 0
        // A still screen: one 1,200-byte packet every 50 ms, about 200 kbps.
        while now < 10_000_000 {
            var batch: [PacketOutcome] = []
            for step in 0..<2 {
                let sentAt = now + Int64(step) * 50_000
                batch.append(PacketOutcome(sequence: sequence, sentAt: sentAt, size: 1_200, arrivedAt: link.carry(sentAt: sentAt, size: 1_200)))
                sequence &+= 1
            }
            now += 100_000
            estimate.update(with: batch, now: now)
        }

        #expect(estimate.target == 8_000_000)
    }

    @Test func `should reach the same target whatever order a report lists its arrivals in`() {
        var link = Link(capacity: 2_000_000)
        var reports: [(outcomes: [PacketOutcome], now: Int64)] = []
        var sequence: UInt16 = 0
        for report in 1...100 {
            let now = Int64(report) * 100_000
            reports.append((stride(from: now - 100_000, to: now, by: 2_500).map { sentAt in
                defer { sequence &+= 1 }
                let jitter = Int64(sequence % 4) * 6_000
                return PacketOutcome(sequence: sequence, sentAt: sentAt, size: 1_200, arrivedAt: link.carry(sentAt: sentAt, size: 1_200).map { $0 + jitter })
            }, now))
        }
        var inOrder = BandwidthEstimate(ceiling: 8_000_000)
        var shuffled = BandwidthEstimate(ceiling: 8_000_000)

        for report in reports {
            inOrder.update(with: report.outcomes, now: report.now)
            // Late arrivals listed first, as a reordered network delivers them.
            shuffled.update(with: report.outcomes.sorted { ($0.arrivedAt ?? 0) > ($1.arrivedAt ?? 0) }, now: report.now)
        }

        #expect(shuffled.target == inOrder.target)
    }

    @Test func `should reach the same target whatever order a report lists a burst sent at one moment`() {
        var link = Link(capacity: 2_000_000)
        var reports: [(outcomes: [PacketOutcome], now: Int64)] = []
        var sequence: UInt16 = 0
        for report in 1...100 {
            // Each 100 ms, a keyframe's 40 packets leave together: more than the link carries.
            let now = Int64(report) * 100_000, sentAt = now - 100_000
            reports.append(((0..<40).map { _ in
                defer { sequence &+= 1 }
                return PacketOutcome(sequence: sequence, sentAt: sentAt, size: 1_200, arrivedAt: link.carry(sentAt: sentAt, size: 1_200))
            }, now))
        }
        var listed = BandwidthEstimate(ceiling: 8_000_000)
        var reversed = BandwidthEstimate(ceiling: 8_000_000)

        for report in reports {
            listed.update(with: report.outcomes, now: report.now)
            reversed.update(with: report.outcomes.reversed(), now: report.now)
        }

        #expect(reversed.target == listed.target)
    }

    @Test func `should measure the same capacity from a burst of mixed sizes, however listed`() {
        // A keyframe's packets leave together; its last is short, so sizes differ.
        var link = Link(capacity: 4_000_000)
        let burst = (0..<12).map { i -> PacketOutcome in
            let size = i == 11 ? 200 : 1_200
            return PacketOutcome(sequence: UInt16(i), sentAt: 0, size: size, arrivedAt: link.carry(sentAt: 0, size: size))
        }
        var listed = BandwidthEstimate(ceiling: 8_000_000)
        var shortFirst = BandwidthEstimate(ceiling: 8_000_000)

        listed.update(with: burst, now: 100_000)
        shortFirst.update(with: [burst[11]] + burst[..<11], now: 100_000)

        #expect(listed.measuredCapacity != nil)
        #expect(shortFirst.measuredCapacity == listed.measuredCapacity)
    }

    @Test func `should never ask for less than its floor`() {
        var estimate = BandwidthEstimate(floor: 300_000, ceiling: 8_000_000)
        var link = Link(capacity: 100_000)

        _ = run(&estimate, over: &link, seconds: 20)

        #expect(estimate.target == 300_000)
    }
}

/// One report's worth (100 ms) of packets at a time, sent every 5 ms from `start`;
/// each one's one-way delay is 50 ms plus `extra(i)` µs.
private func reports(_ count: Int, from start: Int = 0, extra: (Int) -> Int64) -> [[PacketOutcome]] {
    let packets = (start..<(start + count)).map { i in
        PacketOutcome(sequence: UInt16(truncatingIfNeeded: i), sentAt: Int64(i) * 5_000, size: 1_200,
                      arrivedAt: Int64(i) * 5_000 + 50_000 + extra(i))
    }
    return stride(from: 0, to: packets.count, by: 20).map { Array(packets[$0..<min($0 + 20, packets.count)]) }
}

/// A fixed-seed uniform draw in 0..<1 for packet `i`.
private func noise(_ i: Int) -> Double {
    var x = UInt64(i) &* 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    return Double((x ^ (x >> 31)) >> 11) / Double(1 << 53)
}

@Suite("QueueDelay")
struct QueueDelayTests {
    @Test func `should read a link whose delay holds steady as normal`() {
        var queue = QueueDelay()

        for report in reports(400, extra: { _ in 0 }) { queue.read(report) }

        #expect(queue.signal == .normal)
    }

    @Test func `should read a queue that keeps growing as overuse`() {
        var queue = QueueDelay()
        for report in reports(200, extra: { _ in 0 }) { queue.read(report) }

        // Every packet a little later than the last: 1 ms more queue each 5 ms.
        for report in reports(200, from: 200, extra: { Int64($0 - 200) * 1_000 }) { queue.read(report) }

        #expect(queue.signal == .overusing)
    }

    @Test func `should read a queue that drains as underuse`() {
        var queue = QueueDelay()
        for report in reports(200, extra: { _ in 0 }) { queue.read(report) }
        // Up to a 300 ms queue, then draining 4 ms a packet for two reports.
        for report in reports(150, from: 200, extra: { Int64($0 - 200) * 2_000 }) { queue.read(report) }

        for report in reports(40, from: 350, extra: { 300_000 - Int64($0 - 350) * 4_000 }) { queue.read(report) }

        #expect(queue.signal == .underusing)
    }

    @Test(arguments: [40_000, 80_000, 150_000] as [Int64])
    func `should not mistake jitter for a queue`(jitter: Int64) {
        var queue = QueueDelay()

        for report in reports(2_000, extra: { Int64(noise($0) * Double(jitter)) }) { queue.read(report) }

        #expect(queue.signal == .normal)
    }

    @Test func `should not judge a queue from too few packets to have a floor`() {
        var queue = QueueDelay()
        for report in reports(400, extra: { _ in 0 }) { queue.read(report) }

        // A still screen: one late packet a report — a "floor" of one sample is no floor.
        for i in 400..<440 {
            queue.read([PacketOutcome(sequence: UInt16(i), sentAt: Int64(i) * 100_000, size: 1_200,
                                      arrivedAt: Int64(i) * 100_000 + 50_000 + 120_000)])
        }

        #expect(queue.signal == .normal)
    }

    @Test func `should take a path that got longer for good as the new normal`() {
        var queue = QueueDelay()
        for report in reports(200, extra: { _ in 0 }) { queue.read(report) }

        // A route change: every packet 60 ms slower from now on, for 12 s.
        for report in reports(2_400, from: 200, extra: { _ in 60_000 }) { queue.read(report) }

        #expect(queue.signal == .normal)
    }
}
