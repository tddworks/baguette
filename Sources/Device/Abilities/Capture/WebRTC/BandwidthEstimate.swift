import Foundation

/// The bitrate a viewer's encoder should aim for, from the browser's
/// transport-cc reports — Google Congestion Control, as libwebrtc does it:
///
/// - **delay-based**: `DelayTrend`'s signal drives an AIMD rate. Normal climbs
///   (8 % a second, or about one packet per response time once near the link's
///   measured capacity); overuse drops to 85 % of what is actually arriving;
///   underuse holds while the queue drains.
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

    private var trend = DelayTrend()
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

    public init(floor: Int = 300_000, ceiling: Int) {
        self.floor = floor
        self.ceiling = ceiling
        target = ceiling
        delayRate = Double(ceiling)
        lossRate = Double(ceiling)
    }

    /// One report's outcomes, in sending order, read at `now` on the viewer's clock.
    public mutating func update(with outcomes: [PacketOutcome], now: Int64) {
        for outcome in outcomes {
            trend.add(outcome)
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
        guard let first = received.first?.arrival, let last = received.last?.arrival, last - first >= 100_000 else { return nil }
        return Double(received.map(\.bits).reduce(0, +)) / (Double(last - first) / 1_000_000)
    }

    private mutating func updateDelayRate(now: Int64) {
        let elapsed = lastRateUpdate.map { min(Double(now - $0) / 1_000_000, 1) } ?? 0
        lastRateUpdate = now
        switch trend.signal {
        case .normal: if state == .hold { state = .increase }
        case .underusing: state = .hold
        case .overusing: state = .decrease
        }
        switch state {
        case .hold:
            break
        case .increase:
            var increased = delayRate
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
