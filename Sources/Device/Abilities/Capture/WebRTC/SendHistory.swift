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
/// browser's transport-cc reports can be read as outcomes. Bounded: the oldest
/// is forgotten first, and a report about a forgotten packet skips it.
public struct SendHistory: Sendable {
    private let capacity: Int
    private var sent: [UInt16: (at: Int64, size: Int)] = [:]
    private var order: [UInt16] = []

    /// 4096 packets: a few seconds of a busy screen at 8 Mbps.
    public init(capacity: Int = 4096) { self.capacity = capacity }

    public mutating func sent(sequence: UInt16, at microseconds: Int64, size: Int) {
        if sent.updateValue((microseconds, size), forKey: sequence) == nil { order.append(sequence) }
        while order.count > capacity { sent[order.removeFirst()] = nil }
    }

    /// The reported packets it remembers, in the report's order.
    public func outcomes(of feedback: TransportFeedback) -> [PacketOutcome] {
        feedback.arrivals.compactMap { arrival in
            guard let packet = sent[arrival.sequence] else { return nil }
            return PacketOutcome(sequence: arrival.sequence, sentAt: packet.at, size: packet.size, arrivedAt: arrival.microseconds)
        }
    }
}
