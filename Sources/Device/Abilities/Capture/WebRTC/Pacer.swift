import Foundation

/// What spaces a viewer's packets on the wire: a leaky bucket whose normal
/// rate is `pacingFactor` × the target bitrate (faster when its queue couldn't
/// otherwise empty in time, below), as libwebrtc's paced sender
/// and Pion's leaky-bucket pacer do. A keyframe's 60-odd packets leave over
/// ~30 ms instead of in one burst that overflows a phone link's queue; a
/// small frame still leaves at once (a packet into an empty pacer brings
/// `burst` of credit). Time it sat idle is never saved up, and it aims to send
/// every packet within `maxQueueTime`, speeding up as its oldest ages (a
/// target: a late timer can stretch it).
/// Times are microseconds; packets leave in the order they came.
public struct Pacer<Packet>: Sendable where Packet: Sendable {
    /// The bitrate it paces for — the viewer's target.
    public var bitrate: Int

    public static var pacingFactor: Double { 2.5 }      // libwebrtc's kDefaultPaceMultiplier
    public static var burst: Int64 { 5_000 }            // 5 ms of credit, Pion's pacing interval
    public static var maxQueueTime: Int64 { 500_000 }

    private var queue: [(packet: Packet, size: Int, at: Int64)] = []
    private var head = 0
    private var queuedBytes = 0
    private var budget = 0.0      // bytes it may still send
    private var last: Int64 = 0

    /// Off, every packet leaves as soon as it comes — the bench's baseline.
    public let pacing: Bool

    public init(bitrate: Int, pacing: Bool = true) {
        self.bitrate = bitrate
        self.pacing = pacing
    }

    public var isEmpty: Bool { head == queue.count }

    public mutating func enqueue(_ packet: Packet, size: Int, at now: Int64) {
        if isEmpty {
            last = now
            budget = max(budget, Double(Self.burst) * pacedRate / 8_000_000)
        }
        queue.append((packet, size, now))
        queuedBytes += size
    }

    /// The packets whose time has come, in order.
    public mutating func release(at now: Int64) -> [Packet] {
        guard !isEmpty else { return [] }
        guard pacing else {
            defer { queue.removeAll(keepingCapacity: true); head = 0; queuedBytes = 0 }
            return queue[head...].map(\.packet)
        }
        budget += Double(max(now - last, 0)) * rate(at: last) / 8_000_000
        last = now
        var out: [Packet] = []
        while !isEmpty, budget > 0 {
            let next = queue[head]
            head += 1
            queuedBytes -= next.size
            budget -= Double(next.size)
            out.append(next.packet)
        }
        if isEmpty {
            queue.removeAll(keepingCapacity: true)
            head = 0
            budget = min(budget, 0)
        } else if head > 256 {
            queue.removeFirst(head)
            head = 0
        }
        return out
    }

    private var pacedRate: Double { Double(bitrate) * Self.pacingFactor }

    /// The paced rate, or faster when the queue would otherwise keep its
    /// oldest packet past `maxQueueTime`.
    private func rate(at now: Int64) -> Double {
        guard !isEmpty else { return pacedRate }
        let left = max(Self.maxQueueTime - (now - queue[head].at), 1_000)
        return max(pacedRate, Double(queuedBytes * 8) * 1_000_000 / Double(left))
    }
}
