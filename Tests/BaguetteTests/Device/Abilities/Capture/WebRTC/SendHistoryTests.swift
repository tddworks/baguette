import Foundation
import Testing
@testable import BaguetteDevice

private func report(_ arrivals: [(UInt16, Int64?)]) -> TransportFeedback {
    // One two-bit vector chunk per 7 packets would be the wire; here only the parsed value matters.
    TransportFeedback(feedbackCount: 0, arrivals: arrivals.map { .init(sequence: $0.0, microseconds: $0.1) })
}

@Suite("SendHistory")
struct SendHistoryTests {
    @Test func `should pair each reported packet with when it left and how big it was`() {
        var history = SendHistory()
        history.sent(sequence: 10, at: 1_000, size: 1_200)
        history.sent(sequence: 11, at: 1_500, size: 300)

        #expect(history.outcomes(of: report([(10, 50_000), (11, 50_700)]), now: 2_000) == [
            PacketOutcome(sequence: 10, sentAt: 1_000, size: 1_200, arrivedAt: 50_000),
            PacketOutcome(sequence: 11, sentAt: 1_500, size: 300, arrivedAt: 50_700),
        ])
    }

    @Test func `should wait before calling a packet the browser hasn't seen yet lost`() {
        var history = SendHistory()
        history.sent(sequence: 10, at: 1_000, size: 1_200)

        #expect(history.outcomes(of: report([(10, nil)]), now: 100_000).isEmpty)
    }

    @Test func `should report a late packet as arrived when it turns up`() {
        var history = SendHistory()
        history.sent(sequence: 10, at: 1_000, size: 1_200)
        _ = history.outcomes(of: report([(10, nil)]), now: 100_000)

        #expect(history.outcomes(of: report([(10, 180_000)]), now: 200_000) == [
            PacketOutcome(sequence: 10, sentAt: 1_000, size: 1_200, arrivedAt: 180_000),
        ])
    }

    @Test func `should call a packet lost once it has stayed missing for half a second`() {
        var history = SendHistory()
        history.sent(sequence: 10, at: 1_000, size: 1_200)
        history.sent(sequence: 11, at: 2_000, size: 1_200)
        _ = history.outcomes(of: report([(10, nil), (11, 90_000)]), now: 100_000)

        // A later report needn't mention it: half a second after it left, it's lost.
        #expect(history.outcomes(of: report([]), now: 501_000) == [
            PacketOutcome(sequence: 10, sentAt: 1_000, size: 1_200, arrivedAt: nil),
        ])
        #expect(history.outcomes(of: report([(10, 600_000)]), now: 700_000).isEmpty)
    }

    @Test func `should report each packet's outcome once, however often the browser repeats it`() {
        var history = SendHistory()
        history.sent(sequence: 10, at: 1_000, size: 1_200)
        _ = history.outcomes(of: report([(10, 50_000)]), now: 100_000)

        #expect(history.outcomes(of: report([(10, 50_000)]), now: 200_000).isEmpty)
    }

    @Test func `should skip packets it never sent or no longer remembers`() {
        var history = SendHistory(capacity: 2)
        history.sent(sequence: 1, at: 100, size: 10)
        history.sent(sequence: 2, at: 200, size: 10)
        history.sent(sequence: 3, at: 300, size: 10)   // forgets 1

        #expect(history.outcomes(of: report([(1, 1_000), (2, 1_100), (3, 1_200), (99, 1_300)]), now: 2_000).map(\.sequence) == [2, 3])
    }

    @Test func `should pair packets across the sequence wraparound`() {
        var history = SendHistory()
        history.sent(sequence: 65_535, at: 100, size: 10)
        history.sent(sequence: 0, at: 200, size: 10)

        #expect(history.outcomes(of: report([(65_535, 1_000), (0, 1_100)]), now: 2_000).map(\.sentAt) == [100, 200])
    }
}
