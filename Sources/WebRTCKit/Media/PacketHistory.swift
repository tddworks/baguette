import Foundation

/// The packets a sender sent, kept so the browser can ask for them again
/// (NACK) — and the judgement of which of those asks to answer. A resend is
/// what it was sent as; it is skipped when:
///
/// - the packet is older than `maxAge`: its frame is long past;
/// - it was resent less than `resendSpacing` ago: a browser repeats a NACK
///   until the packet arrives, and the last resend is likely still on its way;
/// - resends would take more than `budgetShare` of the target bitrate: a
///   token bucket that refills at that rate and holds a second's worth, so a
///   loss burst can't add congestion of its own (libwebrtc caps them too).
///
/// It holds the last `capacity` packets, each as whatever its sender needs to
/// send it again (the bytes it sent, or the packet to wrap for a resend
/// stream). Times are microseconds.
public struct PacketHistory<Packet: Sendable>: Sendable {
    public static var maxAge: Int64 { 1_000_000 }
    public static var resendSpacing: Int64 { 100_000 }
    public static var budgetShare: Double { 0.5 }

    private struct Sent: Sendable {
        let packet: Packet
        let size: Int
        let at: Int64
        var lastResent: Int64?
    }

    private let capacity: Int
    private var packets: [UInt16: Sent] = [:]
    private var order: [UInt16] = []
    private var budget: Double?       // bytes it may still resend
    private var budgetAt: Int64 = 0

    public init(capacity: Int = 1_024) { self.capacity = capacity }

    /// `packet`, `size` bytes on the wire, sent as `sequence`.
    public mutating func sent(_ packet: Packet, size: Int, sequence: UInt16, at now: Int64) {
        if packets[sequence] == nil { order.append(sequence) }
        packets[sequence] = Sent(packet: packet, size: size, at: now)
        while order.count > capacity { packets[order.removeFirst()] = nil }
    }

    /// The packets to send again for the browser's `lost` report, in its
    /// order, at a moment when the link's target is `target` bits a second.
    public mutating func resend(_ lost: [UInt16], at now: Int64, target: Int) -> [Packet] {
        let rate = Double(target) * Self.budgetShare / 8          // bytes a second
        var available = min(rate, (budget ?? rate) + rate * Double(now - budgetAt) / 1_000_000)
        budgetAt = now
        defer { budget = available }
        var out: [Packet] = []
        for sequence in lost {
            guard var packet = packets[sequence], now - packet.at <= Self.maxAge else { continue }
            if let last = packet.lastResent, now - last < Self.resendSpacing { continue }
            guard available >= Double(packet.size) else { break }
            available -= Double(packet.size)
            packet.lastResent = now
            packets[sequence] = packet
            out.append(packet.packet)
        }
        return out
    }
}

public extension PacketHistory where Packet == Data {
    /// The bytes as they were sent, `sequence`.
    mutating func sent(_ wire: Data, sequence: UInt16, at now: Int64) {
        sent(wire, size: wire.count, sequence: sequence, at: now)
    }
}
