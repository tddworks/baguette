import Foundation
import Testing
@testable import Baguette

/// The order a device takes its gestures in: one at a time, as sent,
/// from every connection — while two devices never wait on each other.
@Suite("GestureQueues")
struct GestureQueuesTests {

    private final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private(set) var most = 0
        func enter() { lock.lock(); now += 1; most = max(most, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
    }

    @Test func `should land a device's gestures one at a time, from every connection`() async {
        let queues = GestureQueues()
        let inFlight = InFlight()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = await queues.run(on: "SIM-1") {
                        inFlight.enter()
                        Thread.sleep(forTimeInterval: 0.02)
                        inFlight.leave()
                        return true
                    }
                }
            }
        }

        #expect(inFlight.most == 1)
    }

    @Test func `should land gestures in the order one connection sends them`() async {
        let queues = GestureQueues()
        let order = OrderBox()

        for step in 0..<5 {
            _ = await queues.run(on: "SIM-1") { order.append(step); return true }
        }

        #expect(order.steps == [0, 1, 2, 3, 4])
    }

    @Test func `should let two devices take gestures at the same time`() async {
        let queues = GestureQueues()
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)

        // Each waits for the other to have started: only both running at
        // once lets either finish in time.
        async let a = queues.run(on: "SIM-1") { () -> Bool in
            first.signal()
            return second.wait(timeout: .now() + 2) == .success
        }
        async let b = queues.run(on: "SIM-2") { () -> Bool in
            second.signal()
            return first.wait(timeout: .now() + 2) == .success
        }

        #expect(await a)
        #expect(await b)
    }

    private final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steps: [Int] = []
        func append(_ step: Int) { lock.lock(); steps.append(step); lock.unlock() }
    }
}
