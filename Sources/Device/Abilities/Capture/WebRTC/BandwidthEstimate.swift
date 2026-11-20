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

    public typealias CutCause = BitrateCut.Cause
    public typealias Cut = BitrateCut

    /// The last cut it made, or nil while it has made none.
    public private(set) var lastCut: Cut?

    private var queue = QueueDelay()
    private var burstCapacity: (at: Int64, bitsPerSecond: Double)?
    /// The rate held when the last cut came: where to climb back to, fast.
    private var beforeCut: Double?
    private var cutInCurrentQueue = false
    private var delayRate: Double
    private var lossRate: Double
    private var lastRateUpdate: Int64?
    private var linkCapacity: Double?
    private var received: [(arrival: Int64, bits: Int)] = []
    private var lossCounted = (lost: 0, total: 0)
    private var lastLossIncrease: Int64?
    private var lastLossDecrease: Int64?
    /// When a queue first cut the rate, once per episode.
    private var lastQueueCutAt: Int64?
    /// A capacity the queue confirmed — it built again soon after a cut — and
    /// when: while it holds, no fast climb goes past it.
    private var confirmedCapacity: (at: Int64, bitsPerSecond: Double)?

    // draft-ietf-rmcat-gcc §5.5, libwebrtc aimd_rate_control.cc / send_side_bandwidth_estimation.cc.
    private static let backoff = 0.85
    private static let multiplicativeIncrease = 1.08        // per second
    private static let additiveIncrease = 1_200.0 * 8 / 0.2  // one packet per ~200 ms response time, per second
    private static let nearCapacity = 0.2                   // within 20 % of the measured capacity
    private static let ackWindow: Int64 = 500_000
    private static let burstPackets = 10                    // a burst this big measures the link
    private static let burstFreshness: Int64 = 5_000_000    // trusted for 5 s
    private static let recovery = 1.5                       // per second, back toward the rate before a cut
    private static let confirmWindow: Int64 = 10_000_000    // a second queue cut this soon confirms the first

    public init(floor: Int = 300_000, ceiling: Int) {
        self.floor = floor
        self.ceiling = ceiling
        target = ceiling
        delayRate = Double(ceiling)
        lossRate = Double(ceiling)
    }

    /// One report's outcomes, read at `now` on the viewer's clock; in whatever
    /// order they come, they are read in sending order.
    @discardableResult
    public mutating func update(with listed: [PacketOutcome], now: Int64) -> Cut? {
        let outcomes = listed.sorted { $0.sentAt < $1.sentAt }
        queue.read(outcomes)
        measureBursts(in: outcomes, now: now)
        countArrivalsAndLosses(in: outcomes)

        let queueCut = updateDelayRate(now: now)
        let lossCut = updateLossRate(now: now)
        return chooseTarget(queueCut: queueCut, lossCut: lossCut, now: now)
    }

    private mutating func countArrivalsAndLosses(in outcomes: [PacketOutcome]) {
        for outcome in outcomes {
            lossCounted.total += 1
            if let arrival = outcome.arrivedAt {
                received.append((arrival, outcome.size * 8))
            } else {
                lossCounted.lost += 1
            }
        }
        // The window ends at the latest arrival, whichever packet it was.
        if let latest = received.map(\.arrival).max() { received.removeAll { $0.arrival < latest - Self.ackWindow } }
    }

    private mutating func chooseTarget(queueCut: CutCause?, lossCut: CutCause?, now: Int64) -> Cut? {
        let previous = target
        target = Int(bounded(min(delayRate, lossRate)))
        guard target < previous, let cause = delayRate <= lossRate ? queueCut : lossCut else { return nil }
        let cut = Cut(at: now, cause: cause, to: target)
        lastCut = cut
        return cut
    }

    /// The link's capacity as its latest burst measured it, in bits per second.
    var measuredCapacity: Double? { burstCapacity?.bitsPerSecond }

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
            // The spread starts when the first packet arrived: the bits that crossed in it are
            // every other packet's, whichever order the report lists them in.
            let first = burst.min { ($0.arrivedAt!, $0.size) < ($1.arrivedAt!, $1.size) }!
            let bits = Double((burst.map(\.size).reduce(0, +) - first.size) * 8)
            burstCapacity = (now, spread > 0 ? bits / spread : Double(ceiling) * 10)
        }
    }

    private mutating func updateDelayRate(now: Int64) -> CutCause? {
        let elapsed = lastRateUpdate.map { min(Double(now - $0) / 1_000_000, 1) } ?? 0
        lastRateUpdate = now
        switch queue.signal {
        case .normal:
            cutInCurrentQueue = false
            increaseDelayRate(elapsed: elapsed, now: now)
            return nil
        case .underusing:
            return nil
        case .overusing:
            return cutDelayRate(now: now)
        }
    }

    private mutating func increaseDelayRate(elapsed: Double, now: Int64) {
        let arriving = acknowledged
        refreshConfirmedCapacity(arriving: arriving, now: now)
        let recovered = fastRecoveryRate(elapsed: elapsed, now: now)
        let increased = stepUp(from: recovered, elapsed: elapsed)

        // A still screen may send less than it could. Its arrival rate limits
        // the increase only, so it cannot make the estimate fall.
        let arrivalLimit = arriving.map { max(delayRate, 1.5 * $0 + 10_000) } ?? .infinity
        delayRate = bounded(min(increased, arrivalLimit))
    }

    private mutating func refreshConfirmedCapacity(arriving: Double?, now: Int64) {
        guard let confirmedCapacity else { return }
        let expired = now - confirmedCapacity.at > Self.confirmWindow
        let improved = (arriving ?? 0) > confirmedCapacity.bitsPerSecond * (1 + Self.nearCapacity)
        if expired || improved { self.confirmedCapacity = nil }
    }

    private func fastRecoveryRate(elapsed: Double, now: Int64) -> Double {
        let limit = confirmedCapacity?.bitsPerSecond ?? .infinity
        var rate = delayRate
        if let measured = burstCapacity, now - measured.at <= Self.burstFreshness {
            rate = max(rate, min(Self.backoff * measured.bitsPerSecond, limit))
        }
        // Restore the rate before a possible jitter spike while the queue stays clear.
        if let beforeCut, delayRate < beforeCut {
            rate = max(rate, min(beforeCut, delayRate * pow(Self.recovery, elapsed), limit))
        }
        return rate
    }

    private mutating func stepUp(from rate: Double, elapsed: Double) -> Double {
        if let linkCapacity, abs(delayRate - linkCapacity) <= Self.nearCapacity * linkCapacity {
            return rate + Self.additiveIncrease * elapsed
        }
        if let linkCapacity, delayRate > linkCapacity * (1 + Self.nearCapacity) { self.linkCapacity = nil }
        return rate * pow(Self.multiplicativeIncrease, elapsed)
    }

    private mutating func cutDelayRate(now: Int64) -> CutCause? {
        guard let arriving = acknowledged else { return nil }
        linkCapacity = linkCapacity.map { 0.95 * $0 + 0.05 * arriving } ?? arriving
        let cut = bounded(Self.backoff * arriving)
        guard cut < delayRate else { return nil }
        rememberQueueCut(arriving: arriving, now: now)
        delayRate = cut
        return .queue(delay: queue.queue)
    }

    private mutating func rememberQueueCut(arriving: Double, now: Int64) {
        // Several reports can describe the same queue. Keep its first cut.
        guard !cutInCurrentQueue else { return }
        beforeCut = delayRate
        cutInCurrentQueue = true
        if let lastQueueCutAt, now - lastQueueCutAt <= Self.confirmWindow {
            confirmedCapacity = (now, arriving)
        }
        lastQueueCutAt = now
    }

    private mutating func updateLossRate(now: Int64) -> CutCause? {
        guard lossCounted.total >= 20 else { return nil }
        let loss = Double(lossCounted.lost) / Double(lossCounted.total)
        lossCounted = (0, 0)
        switch loss {
        case ..<0.02:
            if let lastLossIncrease, now - lastLossIncrease < 1_000_000 { return nil }
            lossRate = bounded(lossRate * Self.multiplicativeIncrease)
            lastLossIncrease = now
            return nil
        case 0.02...0.10:
            return nil
        default:
            if let lastLossDecrease, now - lastLossDecrease < 300_000 { return nil }
            lossRate = bounded(lossRate * (1 - 0.5 * loss))
            lastLossDecrease = now
            return .loss(loss)
        }
    }

    private func bounded(_ rate: Double) -> Double {
        min(max(rate, Double(floor)), Double(ceiling))
    }
}
