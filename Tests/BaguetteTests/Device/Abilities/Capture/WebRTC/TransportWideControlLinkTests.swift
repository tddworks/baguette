import Foundation
import Testing
@testable import BaguetteDevice

/// A real-shaped link: a bottleneck of `capacity` bits per second after
/// `latency`, then up to `jitter` of extra delay per packet — so packets
/// arrive out of order, as over Wi-Fi, 5G and a tunnel. Every `lossEvery`th
/// packet is dropped. Seeded, so a run repeats exactly.
private struct Network {
    var capacity: Double
    var jitter: Int64 = 15_000
    var latency: Int64 = 20_000
    var lossEvery: Int? = nil
    /// A mobile link's radio frames: what crossed is handed over only at the
    /// next frame boundary, so packets that left spread out arrive bunched.
    var batching: Int64? = nil
    private var freeAt: Int64 = 0
    private var count = 0
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(capacity: Double, jitter: Int64 = 15_000, lossEvery: Int? = nil, batching: Int64? = nil) {
        self.capacity = capacity
        self.jitter = jitter
        self.lossEvery = lossEvery
        self.batching = batching
    }

    private mutating func random() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }

    mutating func carry(sentAt: Int64, size: Int) -> Int64? {
        count += 1
        if let every = lossEvery, count % every == 0 { return nil }
        let start = max(sentAt + latency, freeAt)
        freeAt = start + Int64(Double(size * 8) / capacity * 1_000_000)
        let arrival = freeAt + Int64(random() * Double(jitter))
        guard let frame = batching else { return arrival }
        return (arrival / frame + 1) * frame
    }
}

/// A viewer's screen stream over `network`, reported on as Chrome does: every
/// 100 ms, the run from the oldest unreported packet up to the newest arrival,
/// with gaps marked not received (and reported again until they arrive).
/// `screen`: what the encoder has to send, at most the target — 300 kbps for a
/// still screen, infinity for one that never stops moving. A keyframe burst of
/// 60 packets leaves every 2 s, as the encoder makes them.
/// `browserClock`: where the browser's clock stands at our zero. Its reports
/// carry a 24-bit reference time in 64 ms steps, which wraps every ~12.4 days.
private func stream(
    _ control: TransportWideControl, over network: inout Network, screen: Double,
    seconds: Double, from start: Int64 = 0, browserClock: Int64 = 0,
    afterEachReport: (Int) -> Void = { _ in }
) -> Int64 {
    var now = start
    var owed = 0.0
    var inFlight: [(sequence: UInt16, arrival: Int64?)] = []
    func send(at time: Int64) {
        let sequence = control.extensions(at: time).first.map { UInt16($0.data[0]) << 8 | UInt16($0.data[1]) }!
        control.sent(size: 1_200, at: time)
        inFlight.append((sequence, network.carry(sentAt: time, size: 1_200)))
    }
    let end = start + Int64(seconds * 1_000_000)
    while now < end {
        if now % 2_000_000 == 0 { for _ in 0..<60 { send(at: now) } }
        owed += min(Double(control.target ?? 0), screen) * 0.005 / 8
        while owed >= 1_200 {
            owed -= 1_200
            send(at: now)
        }
        now += 5_000
        if now % 100_000 == 0, let newest = inFlight.lastIndex(where: { ($0.arrival ?? .max) <= now }) {
            let run = inFlight[...newest]
            // The reference is the first arrival's, in 64 ms steps, as 24 signed bits.
            let firstArrival = run.compactMap(\.arrival).filter { $0 <= now }.min()! + browserClock
            let steps = firstArrival / 64_000
            let wrapped = (steps + 0x80_0000) % 0x100_0000 - 0x80_0000
            let shift = (steps - wrapped) * 64_000
            control.heard(.transportFeedback(TransportFeedback(feedbackCount: 0, reference: wrapped * 64_000, arrivals: run.map {
                .init(sequence: $0.sequence, microseconds: ($0.arrival ?? .max) <= now ? $0.arrival! + browserClock - shift : nil)
            })), at: now)
            afterEachReport(control.target!)
            // What arrived is reported once; a gap is reported again until it fills.
            inFlight = run.filter { ($0.arrival ?? .max) > now } + inFlight[(newest + 1)...]
        }
    }
    return now
}

@Suite("TransportWideControl over a real-shaped link")
struct TransportWideControlLinkTests {
    @Test func `should keep its bitrate for a still screen sending in bursts over a jittery link with room to spare`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 20_000_000)

        _ = stream(control, over: &network, screen: 300_000, seconds: 30)

        #expect(control.target == 8_000_000)
    }

    @Test(arguments: [40_000, 80_000, 150_000] as [Int64])
    func `should keep its bitrate over a link that jitters this much, with room to spare`(jitter: Int64) {
        for screen in [300_000.0, .infinity] {
            let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
            var network = Network(capacity: 20_000_000, jitter: jitter)

            _ = stream(control, over: &network, screen: screen, seconds: 30)

            #expect(control.target! >= 7_600_000, "jitter \(jitter / 1_000) ms, screen \(screen)")
        }
    }

    @Test func `should keep its bitrate for a busy screen over a jittery link with room to spare`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 20_000_000)

        _ = stream(control, over: &network, screen: .infinity, seconds: 30)

        #expect(control.target == 8_000_000)
    }

    @Test func `should still settle under a link slower than a busy screen sends`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 2_000_000)

        _ = stream(control, over: &network, screen: .infinity, seconds: 20)

        #expect(control.target! <= 2_200_000)
        #expect(control.target! >= 1_000_000)
    }

    @Test func `should still settle under a slow link while the browser's reference clock wraps`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 2_000_000)
        let wrapsIn1s: Int64 = 0x80_0000 * 64_000 - 1_000_000

        _ = stream(control, over: &network, screen: .infinity, seconds: 20, browserClock: wrapsIn1s)

        #expect(control.target! <= 2_200_000)
        #expect(control.target! >= 1_000_000)
    }

    @Test func `should hold near a mobile link's capacity instead of climbing back over it every second`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 5_000_000, batching: 20_000)
        let settled = stream(control, over: &network, screen: .infinity, seconds: 10)

        var targets: [Int] = []
        _ = stream(control, over: &network, screen: .infinity, seconds: 20, from: settled) { targets.append($0) }

        #expect(targets.max()! <= 6_500_000, "climbed to \(targets.max()! / 1_000) kbps on a 5,000 kbps link")
        #expect(targets.min()! >= 2_500_000, "fell to \(targets.min()! / 1_000) kbps")
    }

    @Test func `should be back near its ceiling within six seconds of the link freeing up`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 2_000_000)
        let later = stream(control, over: &network, screen: .infinity, seconds: 20)

        network.capacity = 50_000_000
        _ = stream(control, over: &network, screen: .infinity, seconds: 6, from: later)

        #expect(control.target! >= 7_000_000, "\(control.target!)")
    }

    @Test func `should still cut its bitrate on a link that really loses much of what it sends`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        var network = Network(capacity: 50_000_000, lossEvery: 5)   // 20 % loss

        _ = stream(control, over: &network, screen: .infinity, seconds: 10)

        #expect(control.target! <= 4_000_000)
    }
}
