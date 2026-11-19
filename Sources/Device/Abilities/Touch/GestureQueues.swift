import Foundation

/// The order each device takes its gestures in: one at a time, as sent,
/// from every connection that drives it — a page's stream, another tab,
/// `POST …/input`. A drag holds its fingers for its duration, and a second
/// gesture landing mid-drag would interleave its fingers with the first's.
/// Two devices never wait on each other.
///
/// Gestures run off the caller's thread, so a drag never holds an event
/// loop or the main thread for its length. An input whose message must be
/// built on the main thread (a simulator's Indigo HID) hops there for that
/// call alone.
public final class GestureQueues: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]

    public init() {}

    /// Run `gesture` on the device `id` names, after every gesture sent to
    /// it before, and answer what it answered.
    public func run<T: Sendable>(on id: String, _ gesture: @escaping @Sendable () -> T) async -> T {
        let queue = self.queue(for: id)
        return await withCheckedContinuation { done in
            queue.async { done.resume(returning: gesture()) }
        }
    }

    private func queue(for id: String) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[id] { return queue }
        let queue = DispatchQueue(label: "baguette.gestures.\(id)")
        queues[id] = queue
        return queue
    }
}
