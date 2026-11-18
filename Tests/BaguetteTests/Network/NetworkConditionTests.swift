import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `NetworkCondition` — how degraded a simulator's
/// network is claimed to be.
///
/// Validation lives in the value rather than at each entry point because
/// there are three of them (CLI, HTTP route, browser card) and a condition
/// that only *some* of them check is a condition that eventually arrives
/// nonsensical. A nonsensical throttle doesn't fail loudly; it reads as
/// "the app is slow".
@Suite("NetworkCondition")
struct NetworkConditionTests {

    @Test func `should describe a degraded network from plain numbers`() {
        let condition = NetworkCondition(
            latencyMs: 300, bandwidthKbps: 400, lossPercent: 5)
        #expect(condition?.latencyMs == 300)
        #expect(condition?.bandwidthKbps == 400)
        #expect(condition?.lossPercent == 5)
        #expect(condition?.isOffline == false)
    }

    @Test func `should leave the bandwidth unmetered when none is given`() {
        // Latency without a bandwidth cap is a normal thing to ask for —
        // "make every request wait, but let bytes arrive at full speed".
        // Nil says that; a zero would have to mean either "unlimited" or
        // "nothing gets through", and it can't mean both.
        let condition = NetworkCondition(latencyMs: 300)
        #expect(condition?.bandwidthKbps == nil)
    }

    @Test func `should reject a negative latency`() {
        #expect(NetworkCondition(latencyMs: -1) == nil)
    }

    @Test func `should reject a bandwidth of zero or less`() {
        // Zero kbps is not "very slow", it's "never arrives" — which is
        // what `offline` already says, honestly and immediately.
        #expect(NetworkCondition(bandwidthKbps: 0) == nil)
        #expect(NetworkCondition(bandwidthKbps: -100) == nil)
    }

    @Test func `should reject a loss percentage outside nought to a hundred`() {
        #expect(NetworkCondition(lossPercent: -1) == nil)
        #expect(NetworkCondition(lossPercent: 101) == nil)
        #expect(NetworkCondition(lossPercent: 0) != nil)
        #expect(NetworkCondition(lossPercent: 100) != nil)
    }

    @Test func `should reject numbers that are not finite`() {
        // A JSON body can carry these, and infinity as a latency means an
        // app that hangs forever with no explanation.
        #expect(NetworkCondition(latencyMs: .infinity) == nil)
        #expect(NetworkCondition(bandwidthKbps: .infinity) == nil)
        #expect(NetworkCondition(lossPercent: .nan) == nil)
    }

    @Test func `should go offline without needing any other numbers`() {
        let condition = NetworkCondition.offline
        #expect(condition.isOffline)
        #expect(condition.lossPercent == 0)
    }

    @Test func `should describe the condition in one line a human can read back`() {
        // What the CLI prints, what the server logs, and what the browser
        // card's armed badge shows. It is the sentence someone reads when
        // they are working out why their app feels slow, so each state has
        // to say something true and distinct.
        #expect(NetworkCondition.offline.summary == "offline")
        #expect(NetworkCondition.unconditioned.summary == "nothing")
        #expect(NetworkProfile.threeG.condition.summary == "200 ms latency, 780 kbps")
        #expect(NetworkProfile.totalLoss.condition.summary == "100% loss")
        #expect(NetworkCondition(latencyMs: 300)?.summary == "300 ms latency")
        #expect(NetworkCondition(bandwidthKbps: 400)?.summary == "400 kbps")
        #expect(NetworkCondition(latencyMs: 300, bandwidthKbps: 400, lossPercent: 5)?.summary
                    == "300 ms latency, 400 kbps, 5% loss")
    }

    @Test func `should describe the network only as offline when offline, whatever else was set`() {
        // A device reporting no connection is not also "300 ms latency" —
        // nothing is travelling for that to describe.
        let condition = NetworkCondition(latencyMs: 300, isOffline: true)
        #expect(condition?.summary == "offline")
    }

    @Test func `should know when the network is not being conditioned at all`() {
        // What `network clear` leaves behind, and what the browser card
        // needs in order to decide whether to show its armed badge. A
        // forgotten throttle is invisible, so "is anything on?" has to be
        // answerable without interpreting four numbers.
        #expect(NetworkCondition.unconditioned.isUnconditioned)
        #expect(NetworkCondition(latencyMs: 0)?.isUnconditioned == true)
        #expect(NetworkCondition(latencyMs: 1)?.isUnconditioned == false)
        #expect(NetworkCondition(bandwidthKbps: 400)?.isUnconditioned == false)
        #expect(NetworkCondition(lossPercent: 5)?.isUnconditioned == false)
        #expect(NetworkCondition.offline.isUnconditioned == false)
    }
}
