import Foundation
import Testing
@testable import BaguetteDevice

/// `LatestFrameRules` carried out on a real queue: the consumer is handed
/// frames there, and says when it is ready for the next.
@Suite("LatestFrame")
struct LatestFrameTests {
    private final class Consumer: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [(Int, Date)] = []
        private var readies: [@Sendable () -> Void] = []
        let arrived = DispatchSemaphore(value: 0)
        /// Answer ready at once, or hold each frame until `release()`.
        let holds: Bool
        init(holds: Bool) { self.holds = holds }

        var taken: [Int] { lock.withLock { frames.map(\.0) } }
        var lastAt: Date? { lock.withLock { frames.last?.1 } }

        func take(_ frame: Int, ready: @escaping @Sendable () -> Void) {
            lock.withLock { frames.append((frame, Date())); if holds { readies.append(ready) } }
            if !holds { ready() }
            arrived.signal()
        }

        /// The ready of the oldest frame still held, alone.
        func releaseFirst() {
            let first = lock.withLock { readies.isEmpty ? nil : readies.removeFirst() }
            first?()
        }

        func release() {
            let pending = lock.withLock { () -> [@Sendable () -> Void] in defer { readies = [] }; return readies }
            pending.forEach { $0() }
        }

        func wait(_ seconds: Double = 1) -> Bool { arrived.wait(timeout: .now() + seconds) == .success }
    }

    private func latest(fps: Int, _ consumer: Consumer) -> LatestFrame<Int> {
        LatestFrame<Int>(queue: DispatchQueue(label: "latest-frame-test"), fps: fps) { consumer.take($0, ready: $1) }
    }

    @Test func `should start the newest waiting frame as soon as the consumer is ready`() {
        let consumer = Consumer(holds: true)
        let frames = latest(fps: 0, consumer)
        frames.start()
        frames.offer(1)
        #expect(consumer.wait())

        frames.offer(2)
        frames.offer(3)
        let released = Date()
        consumer.release()

        #expect(consumer.wait())
        #expect(consumer.taken == [1, 3])
        #expect(consumer.lastAt.map { $0.timeIntervalSince(released) < 0.05 } == true)
        frames.stop()
    }

    @Test func `should start a fresh frame once the frame interval has passed`() {
        let consumer = Consumer(holds: false)
        let frames = latest(fps: 10, consumer)
        frames.start()
        frames.offer(1)
        #expect(consumer.wait())

        let offered = Date()
        frames.offer(2)

        #expect(consumer.wait())
        let waited = consumer.lastAt.map { $0.timeIntervalSince(offered) } ?? 0
        #expect(waited > 0.07 && waited < 0.25)
        frames.stop()
    }

    @Test func `should refresh with the last frame when the consumer is idle`() {
        let consumer = Consumer(holds: false)
        let frames = latest(fps: 0, consumer)
        frames.start()
        frames.offer(7)
        #expect(consumer.wait())

        frames.refresh()

        #expect(consumer.wait())
        #expect(consumer.taken == [7, 7])
        frames.stop()
    }

    @Test func `should start nothing after it is stopped`() {
        let consumer = Consumer(holds: false)
        let frames = latest(fps: 0, consumer)
        frames.start()
        frames.offer(1)
        #expect(consumer.wait())

        frames.stop()
        frames.offer(2)
        frames.refresh()

        #expect(!consumer.wait(0.1))
        #expect(consumer.taken == [1])
    }

    @Test func `should not let a frame from before a stop start the next one`() {
        let consumer = Consumer(holds: true)
        let frames = latest(fps: 0, consumer)
        frames.start()
        frames.offer(1)
        #expect(consumer.wait())

        frames.stop()
        frames.start()
        frames.offer(2)
        #expect(consumer.wait())
        frames.offer(3)

        consumer.releaseFirst()     // frame 1's ready, from before the stop
        #expect(!consumer.wait(0.1))
        #expect(consumer.taken == [1, 2])

        consumer.release()          // frame 2's
        #expect(consumer.wait())
        #expect(consumer.taken == [1, 2, 3])
        frames.stop()
    }

    // MARK: - an encoder that stops answering

    private final class Stalls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var seen: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    @Test func `should hand the consumer the next frame when it holds one past the stall limit`() {
        let consumer = Consumer(holds: true)
        let stalls = Stalls()
        let frames = LatestFrame<Int>(
            queue: DispatchQueue(label: "latest-frame-stall"), fps: 0, stallLimit: 0.05, onStall: { stalls.bump() }
        ) { consumer.take($0, ready: $1) }
        frames.start()
        frames.offer(1)
        #expect(consumer.wait())
        frames.offer(2)
        #expect(consumer.wait())
        #expect(consumer.taken == [1, 2])
        #expect(stalls.seen == 1)
        frames.stop()
    }

    @Test func `should never give up on a frame answered within the stall limit`() {
        let consumer = Consumer(holds: false)
        let stalls = Stalls()
        let frames = LatestFrame<Int>(
            queue: DispatchQueue(label: "latest-frame-in-time"), fps: 0, stallLimit: 0.05, onStall: { stalls.bump() }
        ) { consumer.take($0, ready: $1) }
        frames.start()
        frames.offer(1)
        #expect(consumer.wait())
        #expect(!consumer.wait(0.15))
        #expect(stalls.seen == 0)
        frames.stop()
    }
}
