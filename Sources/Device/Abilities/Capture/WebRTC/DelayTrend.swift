import Foundation

/// The delay-based half of Google Congestion Control (draft-ietf-rmcat-gcc,
/// libwebrtc's TrendlineEstimator and its overuse detector): whether the queue
/// in front of the browser is growing, steady or draining, read from how much
/// later each group of packets arrived than it was sent.
///
/// Packets sent within 5 ms of a group's first are one group. For each new
/// group, the delay variation is the change in arrival time minus the change in
/// send time; its running sum, smoothed, is fitted with a line over the last 20
/// groups. A slope above an adaptive threshold for over 10 ms is overuse.
public struct DelayTrend: Sendable {
    public enum Signal: Equatable, Sendable { case normal, overusing, underusing }

    public private(set) var signal = Signal.normal
    public private(set) var groupsSeen = 0

    // libwebrtc defaults (trendline_estimator.cc, inter_arrival_delta.cc).
    private static let groupLength: Int64 = 5_000          // µs
    private static let windowSize = 20
    private static let smoothing = 0.9
    private static let thresholdGain = 4.0
    private static let overuseTime = 10.0                  // ms
    private static let thresholdUp = 0.0087, thresholdDown = 0.039
    private static let thresholdRange = 6.0...600.0

    private struct Group { var firstSent, lastSent, lastArrival: Int64 }
    private var current: Group?
    private var previous: Group?

    private var deltas = 0
    private var accumulated = 0.0
    private var smoothed = 0.0
    private var firstArrival: Double?
    private var history: [(x: Double, y: Double)] = []
    private var trend = 0.0

    private var threshold = 12.5
    private var lastThresholdUpdate: Double?
    private var timeOverUsing = -1.0
    private var overuseCount = 0
    private var previousTrend = 0.0

    public init() {}

    /// One packet's outcome, in sending order; a lost packet says nothing about delay.
    public mutating func add(_ packet: PacketOutcome) {
        guard let arrival = packet.arrivedAt else { return }
        guard var group = current else {
            current = Group(firstSent: packet.sentAt, lastSent: packet.sentAt, lastArrival: arrival)
            groupsSeen += 1
            return
        }
        if packet.sentAt - group.firstSent <= Self.groupLength {
            group.lastSent = max(group.lastSent, packet.sentAt)
            group.lastArrival = max(group.lastArrival, arrival)
            current = group
            return
        }
        if let previous {
            let sendDelta = Double(group.lastSent - previous.lastSent) / 1_000
            let arrivalDelta = Double(group.lastArrival - previous.lastArrival) / 1_000
            update(variation: arrivalDelta - sendDelta, sendDelta: sendDelta, arrivalMs: Double(group.lastArrival) / 1_000)
        }
        previous = group
        current = Group(firstSent: packet.sentAt, lastSent: packet.sentAt, lastArrival: arrival)
        groupsSeen += 1
    }

    private mutating func update(variation: Double, sendDelta: Double, arrivalMs: Double) {
        deltas = min(deltas + 1, 1_000)
        accumulated += variation
        smoothed = Self.smoothing * smoothed + (1 - Self.smoothing) * accumulated
        let first = firstArrival ?? arrivalMs
        firstArrival = first
        history.append((arrivalMs - first, smoothed))
        if history.count > Self.windowSize { history.removeFirst() }
        if history.count == Self.windowSize { trend = Self.slope(history) ?? trend }
        detect(sendDelta: sendDelta, nowMs: arrivalMs)
    }

    private mutating func detect(sendDelta: Double, nowMs: Double) {
        guard deltas >= 2 else { signal = .normal; return }
        let modified = Double(min(deltas, 60)) * trend * Self.thresholdGain
        if modified > threshold {
            timeOverUsing = timeOverUsing < 0 ? sendDelta / 2 : timeOverUsing + sendDelta
            overuseCount += 1
            if timeOverUsing > Self.overuseTime, overuseCount > 1, trend >= previousTrend {
                timeOverUsing = 0
                overuseCount = 0
                signal = .overusing
            }
        } else if modified < -threshold {
            timeOverUsing = -1
            overuseCount = 0
            signal = .underusing
        } else {
            timeOverUsing = -1
            overuseCount = 0
            signal = .normal
        }
        previousTrend = trend
        adaptThreshold(to: modified, nowMs: nowMs)
    }

    /// The threshold follows the trend slowly, faster down than up, so a
    /// competing flow's steady delay doesn't read as overuse forever.
    private mutating func adaptThreshold(to modified: Double, nowMs: Double) {
        let last = lastThresholdUpdate ?? nowMs
        lastThresholdUpdate = nowMs
        guard abs(modified) <= threshold + 15 else { return }
        let gain = abs(modified) < threshold ? Self.thresholdDown : Self.thresholdUp
        threshold += gain * (abs(modified) - threshold) * min(nowMs - last, 100)
        threshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }

    private static func slope(_ points: [(x: Double, y: Double)]) -> Double? {
        let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        return denominator == 0 ? nil : numerator / denominator
    }
}
