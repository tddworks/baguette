import Foundation

/// The bitrate a viewer's encoder should aim for, from the browser's
/// transport-cc reports — Google Congestion Control's shape, with the two
/// parts a screen stream over a mobile link needs done differently:
///
/// - **delay-based**: `QueueDelay`'s signal (the delay floor, which jitter
///   can't lift) drives an AIMD rate. Normal climbs (8 % a second, or about one
///   packet per response time near the link's capacity) and jumps straight to
///   85 % of the capacity its own bursts measured — a keyframe's packets leave
///   together, and how spread out they arrive is the link's rate; overuse drops
///   to 85 % of what is actually arriving; underuse holds while the queue drains.
/// - **loss-based**: under 2 % loss it climbs 8 % (at most once a second);
///   over 10 % it cuts by half the loss (at most every 300 ms).
///
/// The target is the lower of the two, between `floor` and `ceiling` (the
/// bitrate the viewer started at). Times are microseconds; rates bits per second.
public struct BandwidthEstimate: Sendable {
    public let floor: Int
    public let ceiling: Int
    public private(set) var target: Int

    private enum RateState { case hold, increase, decrease }

    private var queue = QueueDelay()
    private var burstCapacity: (at: Int64, bitsPerSecond: Double)?
    /// The rate held when the last cut came: where to climb back to, fast.
    private var beforeCut: Double?
    private var delayRate: Double
    private var lossRate: Double
    private var state = RateState.increase
    private var lastRateUpdate: Int64?
    private var linkCapacity: Double?
    private var received: [(arrival: Int64, bits: Int)] = []
    private var lossCounted = (lost: 0, total: 0)
    private var lastLossIncrease: Int64?
    private var lastLossDecrease: Int64?

    // draft-ietf-rmcat-gcc §5.5, libwebrtc aimd_rate_control.cc / send_side_bandwidth_estimation.cc.
    private static let backoff = 0.85
    private static let multiplicativeIncrease = 1.08        // per second
    private static let additiveIncrease = 1_200.0 * 8 / 0.2  // one packet per ~200 ms response time, per second
    private static let nearCapacity = 0.2                   // within 20 % of the measured capacity
    private static let ackWindow: Int64 = 500_000
    private static let burstPackets = 10                    // a burst this big measures the link
    private static let burstFreshness: Int64 = 5_000_000    // trusted for 5 s
    private static let recovery = 1.5                       // per second, back toward the rate before a cut

    public init(floor: Int = 300_000, ceiling: Int) {
        self.floor = floor
        self.ceiling = ceiling
        target = ceiling
        delayRate = Double(ceiling)
        lossRate = Double(ceiling)
    }

    /// One report's outcomes, read at `now` on the viewer's clock; in whatever
    /// order they come, they are read in sending order.
    public mutating func update(with listed: [PacketOutcome], now: Int64) {
        let outcomes = listed.sorted { $0.sentAt < $1.sentAt }
        queue.read(outcomes)
        measureBursts(in: outcomes, now: now)
        for outcome in outcomes {
            lossCounted.total += 1
            if let arrival = outcome.arrivedAt {
                received.append((arrival, outcome.size * 8))
            } else {
                lossCounted.lost += 1
            }
        }
        if let latest = received.last?.arrival { received.removeAll { $0.arrival < latest - Self.ackWindow } }
        updateDelayRate(now: now)
        updateLossRate(now: now)
        let rate = min(delayRate, lossRate)
        target = Int(min(max(rate, Double(floor)), Double(ceiling)))
    }

    /// What is actually arriving: the bits of the last half second over its span.
    private var acknowledged: Double? {
        // Jitter reorders arrivals: the span is earliest to latest, not first to last.
        let arrivals = received.map(\.arrival)
        guard let first = arrivals.min(), let last = arrivals.max(), last - first >= 100_000 else { return nil }
        return Double(received.map(\.bits).reduce(0, +)) / (Double(last - first) / 1_000_000)
    }

    /// Packets that left together (within 1 ms) and arrived spread over some
    /// time crossed the link back to back: their bits over that spread is its
    /// capacity. Arrived all at once means faster than we can tell: the ceiling's
    /// tenfold.
    private mutating func measureBursts(in outcomes: [PacketOutcome], now: Int64) {
        var bursts: [[PacketOutcome]] = []
        for outcome in outcomes where outcome.arrivedAt != nil {
            if let first = bursts.last?.first, outcome.sentAt - first.sentAt <= 1_000 {
                bursts[bursts.count - 1].append(outcome)
            } else {
                bursts.append([outcome])
            }
        }
        for burst in bursts where burst.count >= Self.burstPackets {
            let arrivals = burst.compactMap(\.arrivedAt)
            let spread = Double(arrivals.max()! - arrivals.min()!) / 1_000_000
            let bits = Double(burst.dropFirst().map(\.size).reduce(0, +) * 8)
            burstCapacity = (now, spread > 0 ? bits / spread : Double(ceiling) * 10)
        }
    }

    private mutating func updateDelayRate(now: Int64) {
        let elapsed = lastRateUpdate.map { min(Double(now - $0) / 1_000_000, 1) } ?? 0
        lastRateUpdate = now
        switch queue.signal {
        case .normal: if state == .hold { state = .increase }
        case .underusing: state = .hold
        case .overusing: state = .decrease
        }
        switch state {
        case .hold:
            break
        case .increase:
            var increased = delayRate
            // The link just showed what it carries: go there at once, not 8 % a second.
            if let measured = burstCapacity, now - measured.at <= Self.burstFreshness {
                increased = max(increased, Self.backoff * measured.bitsPerSecond)
            }
            // A cut the queue never repeated was likely wrong (a jitter spike):
            // climb back fast; on a full link the queue builds again and stops it.
            if let before = beforeCut, delayRate < before {
                increased = max(increased, min(before, delayRate * pow(Self.recovery, elapsed)))
            }
            if let capacity = linkCapacity, abs(delayRate - capacity) <= Self.nearCapacity * capacity {
                increased += Self.additiveIncrease * elapsed
            } else {
                if let capacity = linkCapacity, delayRate > capacity * (1 + Self.nearCapacity) { linkCapacity = nil }
                increased *= pow(Self.multiplicativeIncrease, elapsed)
            }
            // Don't climb far ahead of what is getting through — but a sender
            // that sends less than it may (a still screen) is no reason to
            // come down: the cap only stops an increase (libwebrtc's AIMD).
            if let acknowledged, increased > 1.5 * acknowledged + 10_000 {
                increased = max(delayRate, 1.5 * acknowledged + 10_000)
            }
            delayRate = increased
        case .decrease:
            beforeCut = delayRate
            if let acknowledged {
                delayRate = min(delayRate, Self.backoff * acknowledged)
                linkCapacity = linkCapacity.map { 0.95 * $0 + 0.05 * acknowledged } ?? acknowledged
            }
            state = .hold
        }
        delayRate = min(max(delayRate, Double(floor)), Double(ceiling))
    }

    private mutating func updateLossRate(now: Int64) {
        guard lossCounted.total >= 20 else { return }
        let loss = Double(lossCounted.lost) / Double(lossCounted.total)
        lossCounted = (0, 0)
        if loss < 0.02, lastLossIncrease.map({ now - $0 >= 1_000_000 }) ?? true {
            lossRate *= Self.multiplicativeIncrease
            lastLossIncrease = now
        } else if loss > 0.10, lastLossDecrease.map({ now - $0 >= 300_000 }) ?? true {
            lossRate *= 1 - 0.5 * loss
            lastLossDecrease = now
        }
        lossRate = min(max(lossRate, Double(floor)), Double(ceiling))
    }
}
