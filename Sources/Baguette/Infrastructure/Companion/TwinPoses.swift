import Foundation

/// Per-device attitude fan-out — the motion sibling of `TwinScreens`,
/// held by `Server` for the same reason: pose flows in on the
/// companion's motion socket and out to however many 3D stages are
/// watching, across socket lifetimes. A late subscriber immediately
/// receives the latest sample so a freshly opened twin doesn't sit at
/// identity until the phone moves.
final class TwinPoses: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: AttitudeSample] = [:]
    private var subscribers: [String: [String: @Sendable (AttitudeSample) -> Void]] = [:]

    func update(udid: String, sample: AttitudeSample) {
        lock.lock()
        latest[udid] = sample
        let sinks = Array((subscribers[udid] ?? [:]).values)
        lock.unlock()
        for sink in sinks { sink(sample) }
    }

    func subscribe(udid: String, id: String, handler: @escaping @Sendable (AttitudeSample) -> Void) {
        lock.lock()
        subscribers[udid, default: [:]][id] = handler
        let replay = latest[udid]
        lock.unlock()
        if let replay { handler(replay) }
    }

    func unsubscribe(udid: String, id: String) {
        lock.lock()
        subscribers[udid]?[id] = nil
        lock.unlock()
    }

    /// The companion's motion socket closed — forget the pose so a
    /// reconnecting twin doesn't inherit a stale orientation.
    func clear(udid: String) {
        lock.lock()
        latest[udid] = nil
        lock.unlock()
    }
}
