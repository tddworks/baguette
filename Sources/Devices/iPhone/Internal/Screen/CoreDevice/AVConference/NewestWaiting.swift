import Foundation

/// One value waiting for work, the newest: a later one replaces it, and only
/// the first of a run asks for the work — so a slow conversion drops stale
/// pictures instead of queueing them behind AVConference's real-time thread.
final class NewestWaiting<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Value?

    /// Keep `value` as the one waiting; true when the work should be scheduled.
    func offer(_ value: Value) -> Bool {
        lock.withLock {
            defer { waiting = value }
            return waiting == nil
        }
    }

    /// The value waiting, if any, now no longer waiting.
    func take() -> Value? {
        lock.withLock {
            defer { waiting = nil }
            return waiting
        }
    }
}
