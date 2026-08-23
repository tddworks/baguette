import Testing
@testable import Baguette

@Suite("PendingCapture")
struct PendingCaptureTests {

    @Test func `the first request must be scheduled`() {
        var pending = PendingCapture()
        #expect(pending.request() == true)
    }

    @Test func `repeat requests coalesce onto the one already pending`() {
        var pending = PendingCapture()
        _ = pending.request()
        #expect(pending.request() == false)
        #expect(pending.request() == false)
    }

    @Test func `a request once the capture has begun schedules a fresh one`() {
        var pending = PendingCapture()
        _ = pending.request()
        pending.begin()
        #expect(pending.request() == true)
    }

    @Test func `a burst of notifications during one slow capture yields a single schedule`() {
        var pending = PendingCapture()
        var scheduled = 0
        for _ in 0..<10_000 where pending.request() { scheduled += 1 }
        #expect(scheduled == 1)
    }

    @Test func `each capture cycle schedules exactly once however many frames arrive`() {
        var pending = PendingCapture()
        var scheduled = 0
        for cycle in 0..<5 {
            for _ in 0..<100 where pending.request() { scheduled += 1 }
            pending.begin()          // the queued capture starts running
            #expect(scheduled == cycle + 1)
        }
        #expect(scheduled == 5)
    }
}
