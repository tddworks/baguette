import Foundation

/// A family's device listing that is slow to read — a process to spawn
/// (devicectl ~0.2 s, adb ~25 ms) — while every per-device request asks every
/// family (`CombinedDevices.find`), so a simulator's tap paid each family's
/// read. The first read is waited for, once however many lookups arrive
/// together; for `freshness` after it the last listing answers; after that it
/// still answers at once while a fresh one is read behind (`refresh`), so a
/// device that appears shows within a couple of seconds and no request waits
/// on a read again. A failed read keeps the last good listing.
public final class RecentListing<Item: Sendable>: @unchecked Sendable {
    /// Runs work off the caller's thread.
    public typealias Refresh = @Sendable (_ work: @escaping @Sendable () -> Void) -> Void

    public let freshness: TimeInterval
    private let clock: @Sendable () -> Date
    private let refresh: Refresh
    /// The listing, or nil when it couldn't be read.
    private let read: @Sendable () -> [Item]?
    private let lock = NSLock()
    private let firstLock = NSLock()
    private var listed: (at: Date, items: [Item])?
    private var refreshing = false

    public init(
        freshness: TimeInterval = 2,
        clock: @escaping @Sendable () -> Date = Date.init,
        refresh: @escaping Refresh = { work in DispatchQueue.global(qos: .utility).async(execute: work) },
        read: @escaping @Sendable () -> [Item]?
    ) {
        self.freshness = freshness
        self.clock = clock
        self.refresh = refresh
        self.read = read
    }

    public var items: [Item] {
        let now = clock()
        let (last, stale) = lock.withLock { () -> ([Item]?, Bool) in
            guard let listed else { return (nil, false) }
            let stale = now.timeIntervalSince(listed.at) >= freshness && !refreshing
            if stale { refreshing = true }
            return (listed.items, stale)
        }
        guard let last else { return first() }
        if stale {
            refresh { [self] in
                let items = read()
                lock.withLock {
                    if let items { listed = (clock(), items) }
                    refreshing = false
                }
            }
        }
        return last
    }

    /// The first listing, read once however many lookups arrive together.
    private func first() -> [Item] {
        firstLock.withLock {
            if let listed = lock.withLock({ listed }) { return listed.items }
            let items = read() ?? []
            lock.withLock { listed = (clock(), items) }
            return items
        }
    }
}
