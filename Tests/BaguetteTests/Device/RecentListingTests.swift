import Foundation
import Testing
@testable import BaguetteDevice

/// A listing that is slow to read (a process to spawn): the last one answers,
/// and a stale one is read again behind the caller.
@Suite("RecentListing")
struct RecentListingTests {
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        var next: [String]? = ["first"]
        var delay: useconds_t = 0
        var reads: Int { lock.withLock { _reads } }
        func read() -> [String]? {
            if delay > 0 { usleep(delay) }
            return lock.withLock { _reads += 1; return next }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 0)
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
    }

    private final class Behind: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []
        func add(_ item: @escaping @Sendable () -> Void) { lock.withLock { work.append(item) } }
        func run() { lock.withLock { work }.forEach { $0() } }
    }

    @Test func `should answer from its last listing while it is fresh, without reading again`() {
        let source = Source(), clock = Clock()
        let listing = RecentListing<String>(clock: { clock.now }, refresh: { _ in }, read: source.read)

        _ = listing.items
        clock.now += 1
        let again = listing.items

        #expect(again == ["first"])
        #expect(source.reads == 1)
    }

    @Test func `should answer at once from a stale listing, and read a fresh one behind`() {
        let source = Source(), clock = Clock(), behind = Behind()
        let listing = RecentListing<String>(clock: { clock.now }, refresh: behind.add, read: source.read)
        _ = listing.items

        clock.now += 3
        source.next = ["second"]
        let stale = listing.items
        behind.run()

        #expect(stale == ["first"])
        #expect(listing.items == ["second"])
        #expect(source.reads == 2)
    }

    @Test func `should keep its last listing when a fresh read fails`() {
        let source = Source(), clock = Clock(), behind = Behind()
        let listing = RecentListing<String>(clock: { clock.now }, refresh: behind.add, read: source.read)
        _ = listing.items

        clock.now += 3
        source.next = nil
        _ = listing.items
        behind.run()

        #expect(listing.items == ["first"])
    }

    @Test func `should read once when the first lookups come together`() async {
        let source = Source()
        source.delay = 50_000
        let listing = RecentListing<String>(refresh: { _ in }, read: source.read)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = listing.items } }
        }

        #expect(source.reads == 1)
    }

    @Test func `should have nothing when its first read fails`() {
        let source = Source()
        source.next = nil

        #expect(RecentListing<String>(refresh: { _ in }, read: source.read).items.isEmpty)
    }
}
