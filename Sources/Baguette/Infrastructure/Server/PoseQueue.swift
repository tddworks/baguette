import Foundation

/// One socket's `set_pose` requests, played in the order they came, one
/// at a time. A slider drag sends a burst, and detached drives racing for
/// the motor would leave the hinge wherever the last to win said; a
/// request the burst has already passed is skipped, so the hinge catches
/// up to the thumb rather than replaying its path.
final class PoseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var newest = 0

    func enqueue(_ drive: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        newest += 1
        let mine = newest
        let previous = tail
        tail = Task.detached { [self] in
            await previous?.value
            let stale = self.lock.withLock { mine != self.newest }
            if !stale { drive() }
        }
    }

    /// Returns once everything enqueued so far has played or been skipped.
    func settled() async {
        await lock.withLock { tail }?.value
    }
}
