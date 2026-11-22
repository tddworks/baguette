import Foundation

/// The order each device takes its gestures in: one at a time, as sent,
/// from every connection that drives it — a page's stream, another tab,
/// `POST …/input`. A drag holds its fingers for its duration, and a second
/// gesture landing mid-drag would interleave its fingers with the first's.
/// Two devices never wait on each other.
///
/// A pointer move is posted rather than awaited, and while it waits a newer
/// move replaces it (`PendingGestures`) — so a pointer can't fall behind the
/// hand however fast moves arrive. Everything else keeps its order.
///
/// Gestures run off the caller's thread, so a drag never holds an event
/// loop or the main thread for its length. An input whose message must be
/// built on the main thread (a simulator's Indigo HID) hops there for that
/// call alone.
public final class GestureQueues: @unchecked Sendable {
    private final class Lane: @unchecked Sendable {
        let queue: DispatchQueue
        var pending = PendingGestures<@Sendable () -> Void>()
        var draining = false
        init(_ id: String) { queue = DispatchQueue(label: "baguette.gestures.\(id)") }
    }

    private let lock = NSLock()
    private var lanes: [String: Lane] = [:]

    public init() {}

    /// Run `gesture` on the device `id` names, after every gesture sent to
    /// it before, and answer what it answered.
    public func run<T: Sendable>(on id: String, _ gesture: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            enqueue(on: id, motion: false) { done.resume(returning: gesture()) }
        }
    }

    /// Post a pointer move to the device `id` names, after every gesture sent
    /// before it, without waiting — replaced by a newer move while it waits.
    public func post(on id: String, _ move: @escaping @Sendable () -> Void) {
        enqueue(on: id, motion: true, move)
    }

    private func enqueue(on id: String, motion: Bool, _ work: @escaping @Sendable () -> Void) {
        let (lane, start) = lock.withLock { () -> (Lane, Bool) in
            let lane = lanes[id] ?? Lane(id)
            lanes[id] = lane
            lane.pending.add(work, motion: motion)
            defer { lane.draining = true }
            return (lane, !lane.draining)
        }
        if start { lane.queue.async { [self] in drain(lane) } }
    }

    private func drain(_ lane: Lane) {
        while let work = lock.withLock({ () -> (@Sendable () -> Void)? in
            if let work = lane.pending.next() { return work }
            lane.draining = false
            return nil
        }) {
            work()
        }
    }
}
