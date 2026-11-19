import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("PendingCapture")
struct PendingCaptureTests {

    @Test func `should schedule a capture on the first request`() {
        var pending = PendingCapture()
        #expect(pending.request() == true)
    }

    @Test func `should fold repeat requests into the capture already pending`() {
        var pending = PendingCapture()
        _ = pending.request()
        #expect(pending.request() == false)
        #expect(pending.request() == false)
    }

    @Test func `should schedule a fresh capture when a request arrives after the last one began`() {
        var pending = PendingCapture()
        _ = pending.request()
        pending.begin()
        #expect(pending.request() == true)
    }

    @Test func `should schedule a single capture for a burst of frames during one slow capture`() {
        var pending = PendingCapture()
        var scheduled = 0
        for _ in 0..<10_000 where pending.request() { scheduled += 1 }
        #expect(scheduled == 1)
    }

    @Test func `should schedule exactly once per capture cycle however many frames arrive`() {
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
