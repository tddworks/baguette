import Foundation

/// Whether the queue in front of the browser is building, steady or draining,
/// read the way jitter can't fool: jitter only ever adds delay to *some*
/// packets, while a filling queue raises the delay of *every* packet — so the
/// signal is the floor. The queue is the smallest one-way delay among packets
/// *sent* in the last 200 ms minus the smallest over the last 10 s (the path's
/// own delay); the clocks' offset cancels out. By send time, not by report: a
/// report holds whatever arrived since the last, so after a burst it can hold
/// only the burst's latest arrivals, a floor no packet ever saw. Over 40 ms and not falling is
/// overuse; over 40 ms and falling is a queue draining; otherwise normal. A
/// window of fewer than 10 packets (a still screen) has no floor worth the
/// name: it reads as normal, since without evidence nothing should be cut.
/// (LEDBAT's base-delay idea, in place of GCC's trendline, whose 5 ms groups
/// read a jittery mobile link as a growing queue.)
public struct QueueDelay: Sendable {
    public enum Signal: Equatable, Sendable { case normal, overusing, underusing }

    public private(set) var signal = Signal.normal
    /// The current queueing delay, µs.
    public private(set) var queue: Int64 = 0

    private static let recentWindow: Int64 = 200_000
    private static let baseWindow: Int64 = 10_000_000
    private static let overuse: Int64 = 40_000
    private static let falling: Int64 = 5_000
    private static let enoughPackets = 10

    /// Every arrived packet's one-way delay, by when it was sent, for 10 s.
    private var delays: [(sentAt: Int64, delay: Int64)] = []

    public init() {}

    /// One report's outcomes; lost packets say nothing about delay.
    public mutating func read(_ outcomes: [PacketOutcome]) {
        delays += outcomes.compactMap { packet in packet.arrivedAt.map { (packet.sentAt, $0 - packet.sentAt) } }
        guard let newest = delays.map(\.sentAt).max() else { return }
        delays.removeAll { $0.sentAt < newest - Self.baseWindow }
        let window = delays.filter { $0.sentAt >= newest - Self.recentWindow }
        guard window.count >= Self.enoughPackets else {
            signal = .normal
            return
        }
        guard let base = delays.map(\.delay).min(), let recent = window.map(\.delay).min() else { return }
        let previous = queue
        queue = recent - base
        if queue <= Self.overuse {
            signal = .normal
        } else if queue < previous - Self.falling {
            signal = .underusing
        } else {
            signal = .overusing
        }
    }
}
