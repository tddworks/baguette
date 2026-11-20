import Foundation

/// What became of one packet a viewer sent: when it left and how big it was
/// (on the viewer's clock), and when the browser says it arrived (on the
/// browser's), or nil when it didn't.
public struct PacketOutcome: Equatable, Sendable {
    public let sequence: UInt16
    public let sentAt: Int64
    public let size: Int
    public let arrivedAt: Int64?

    public init(sequence: UInt16, sentAt: Int64, size: Int, arrivedAt: Int64?) {
        self.sequence = sequence
        self.sentAt = sentAt
        self.size = size
        self.arrivedAt = arrivedAt
    }
}

/// The packets a viewer sent lately, by transport-wide sequence number, so the
/// browser's transport-cc reports can be read as outcomes — each packet's
/// once. A browser reports a packet that hasn't arrived *yet* as not
/// received, and again in later reports until it does: over a jittery link
/// that's most packets now and then. So a missing packet is only held; it is
/// lost once it has stayed missing for `lossGrace` after it was sent, and a
/// late one keeps its real arrival time. Bounded: the oldest is forgotten
/// first, and a report about a forgotten packet skips it.
public struct SendHistory: Sendable {
    /// How long a packet may be missing before it counts as lost.
    public static let lossGrace: Int64 = 500_000

    private let capacity: Int
    private var sent: [UInt16: (at: Int64, size: Int)] = [:]
    private var order: [UInt16] = []
    private var missing: Set<UInt16> = []

    /// 4096 packets: a few seconds of a busy screen at 8 Mbps.
    public init(capacity: Int = 4096) { self.capacity = capacity }

    public mutating func sent(sequence: UInt16, at microseconds: Int64, size: Int) {
        if sent.updateValue((microseconds, size), forKey: sequence) == nil { order.append(sequence) }
        missing.remove(sequence)
        while order.count > capacity {
            let oldest = order.removeFirst()
            sent[oldest] = nil
            missing.remove(oldest)
        }
    }

    /// What this report settles, read at `now` on the viewer's clock, in
    /// sending order: packets newly arrived, and packets now missing for longer
    /// than `lossGrace`.
    public mutating func outcomes(of feedback: TransportFeedback, now: Int64) -> [PacketOutcome] {
        var settled: [PacketOutcome] = []
        for arrival in feedback.arrivals {
            guard let packet = sent[arrival.sequence] else { continue }
            if let arrivedAt = arrival.microseconds {
                settled.append(PacketOutcome(sequence: arrival.sequence, sentAt: packet.at, size: packet.size, arrivedAt: arrivedAt))
                sent[arrival.sequence] = nil
                missing.remove(arrival.sequence)
            } else {
                missing.insert(arrival.sequence)
            }
        }
        for sequence in missing {
            guard let packet = sent[sequence], now - packet.at >= Self.lossGrace else { continue }
            settled.append(PacketOutcome(sequence: sequence, sentAt: packet.at, size: packet.size, arrivedAt: nil))
            sent[sequence] = nil
            missing.remove(sequence)
        }
        return settled.sorted { $0.sentAt < $1.sentAt }
    }
}
