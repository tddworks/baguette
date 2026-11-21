import Testing
@testable import BaguetteDevice

/// The rules for handing a screen's newest frame to one consumer: newest wins,
/// one in flight, a rate counted from fresh frames only, refreshes only when idle.
@Suite("LatestFrameRules")
struct LatestFrameRulesTests {
    @Test func `should start a fresh frame at once when the consumer is idle`() {
        var rules = LatestFrameRules<Int>(fps: 60)

        #expect(rules.offer(1, at: 0) == .start(1))
    }

    @Test func `should keep only the newest frame while the consumer is busy`() {
        var rules = LatestFrameRules<Int>(fps: 0)
        _ = rules.offer(1, at: 0)

        let second = rules.offer(2, at: 0.001)
        let third = rules.offer(3, at: 0.002)

        #expect(second == .nothing && third == .nothing)
        #expect(rules.ready(at: 0.003) == .start(3))
        #expect(rules.ready(at: 0.004) == .nothing)
    }

    @Test func `should start the waiting frame when the consumer is ready`() {
        var rules = LatestFrameRules<Int>(fps: 0)
        _ = rules.offer(1, at: 0)
        _ = rules.offer(2, at: 0.001)

        #expect(rules.ready(at: 0.004) == .start(2))
    }

    @Test func `should wait out the frame interval after a fresh frame`() {
        var rules = LatestFrameRules<Int>(fps: 10)
        _ = rules.offer(1, at: 0)
        _ = rules.ready(at: 0.01)

        #expect(rules.offer(2, at: 0.02) == .wake(at: 0.1))
        #expect(rules.due(at: 0.05) == .wake(at: 0.1))
        #expect(rules.due(at: 0.1) == .start(2))
    }

    @Test func `should start about 30 frames a second when frames arrive at 60 Hz`() {
        var rules = LatestFrameRules<Int>(fps: 30)
        var started: [Int] = []
        var wake: Double?
        for index in 0...60 {
            let now = Double(index) / 60
            if let due = wake, now >= due, case .start(let frame) = rules.due(at: due) { started.append(frame); _ = rules.ready(at: due) }
            wake = nil
            switch rules.offer(index, at: now) {
            case .start(let frame): started.append(frame); _ = rules.ready(at: now)
            case .wake(let at): wake = at
            case .nothing: break
            }
        }
        if let due = wake, case .start(let frame) = rules.due(at: due) { started.append(frame) }

        #expect(started.first == 0 && started.last == 60)
        #expect((28...32).contains(started.count))
    }

    @Test func `should count a frame a hair early as on time, as a recording does`() {
        var rules = LatestFrameRules<Int>(fps: 10)
        _ = rules.offer(1, at: 0)
        _ = rules.ready(at: 0.01)

        #expect(rules.offer(2, at: 0.096) == .start(2))
    }

    @Test func `should never hold a fresh frame back for a refresh`() {
        var rules = LatestFrameRules<Int>(fps: 10)
        _ = rules.offer(1, at: 0)
        _ = rules.ready(at: 0.01)
        #expect(rules.refresh() == .start(1))
        _ = rules.ready(at: 0.12)

        #expect(rules.offer(2, at: 0.125) == .start(2))
    }

    @Test func `should refresh with the last frame only when nothing is in flight or waiting`() {
        var rules = LatestFrameRules<Int>(fps: 10)
        #expect(rules.refresh() == .nothing)
        _ = rules.offer(1, at: 0)
        #expect(rules.refresh() == .nothing)
        _ = rules.ready(at: 0.01)
        _ = rules.offer(2, at: 0.02)

        #expect(rules.refresh() == .nothing)
        #expect(rules.due(at: 0.1) == .start(2))
        _ = rules.ready(at: 0.11)
        #expect(rules.refresh() == .start(2))
    }

    @Test func `should start nothing once cleared`() {
        var rules = LatestFrameRules<Int>(fps: 0)
        _ = rules.offer(1, at: 0)
        _ = rules.offer(2, at: 0.001)

        rules.clear()

        #expect(rules.ready(at: 0.002) == .nothing)
        #expect(rules.refresh() == .nothing)
        #expect(rules.offer(3, at: 0.003) == .start(3))
    }

    @Test func `should take a new rate from the next frame on`() {
        var rules = LatestFrameRules<Int>(fps: 10)
        _ = rules.offer(1, at: 0)
        _ = rules.ready(at: 0.01)

        rules.fps = 50

        #expect(rules.offer(2, at: 0.02) == .start(2))
    }
}
