import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `MotionLedger` — the running totals a
/// `CMPedometer` reports.
///
/// A pedometer is **cumulative**: an app that charts a day's steps must
/// see them keep climbing across a walk → stop → walk sequence. Every
/// change of intent therefore banks what the previous leg earned, and the
/// banked figure rides along in the next intent as `stepsBefore` /
/// `distanceBefore`. This value is that banking, and it lives in Swift so
/// the arithmetic is tested rather than trusted to the dylib.
@Suite("MotionLedger")
struct MotionLedgerTests {

    /// 1.5 m/s over a 0.75 m stride = exactly 2 steps a second.
    private func walk(startedAt: Double) -> MotionIntent {
        MotionIntent(kind: .walking, confidence: .high, speed: 1.5,
                     startedAt: startedAt, stepsBefore: 0, distanceBefore: 0)
    }

    @Test func `should bank nothing for a leg that has not run yet`() {
        let banked = MotionLedger.empty.banking(walk(startedAt: 1000), at: 1000)
        #expect(banked == .empty)
    }

    @Test func `should bank whole steps only`() {
        // 10.5 s at 2 steps/s = 21 steps, not 21.5. Half a step has not
        // been taken.
        let banked = MotionLedger.empty.banking(walk(startedAt: 1000), at: 1010.5)
        #expect(banked.steps == 21)
    }

    @Test func `should keep distance exactly consistent with whole steps`() {
        // Distance is derived from steps × stride rather than speed ×
        // elapsed, so an app can never read a distance that disagrees with
        // the step count it was given alongside it.
        let banked = MotionLedger.empty.banking(walk(startedAt: 1000), at: 1010.5)
        #expect(banked.metres == 21 * 0.75)
    }

    @Test func `should carry earlier totals forward`() {
        let earlier = MotionLedger(steps: 812, metres: 610)
        let banked = earlier.banking(walk(startedAt: 1000), at: 1005)
        #expect(banked.steps == 812 + 10)
        #expect(banked.metres == 610 + 10 * 0.75)
    }

    @Test func `should accrue nothing while driving or cycling`() {
        // No stride means no steps, and a pedometer that logged road miles
        // as walking distance would corrupt an app's daily total.
        for kind in [MotionKind.automotive, .cycling] {
            let leg = MotionIntent(kind: kind, confidence: .high, speed: 20,
                                   startedAt: 1000, stepsBefore: 0, distanceBefore: 0)
            #expect(MotionLedger.empty.banking(leg, at: 1100) == .empty)
        }
    }

    @Test func `should accrue nothing while stationary`() {
        let still = MotionIntent.stationary(startedAt: 1000, stepsBefore: 0, distanceBefore: 0)
        #expect(MotionLedger.empty.banking(still, at: 1100) == .empty)
    }

    @Test func `should ignore a leg that appears to have run backwards`() {
        // Clock skew must not rewind a cumulative counter.
        let banked = MotionLedger(steps: 5, metres: 3.75)
            .banking(walk(startedAt: 1000), at: 900)
        #expect(banked.steps == 5)
        #expect(banked.metres == 3.75)
    }

    @Test func `should resume the totals a published intent was carrying`() {
        // The CLI holds no session state — each `baguette motion set` is a
        // fresh process. Without this it published `stepsBefore: 0` every
        // time and an app's step count restarted on every command.
        // Reconstructing from the published intent means the file itself is
        // the state, and the CLI and the server agree.
        let published = MotionIntent(kind: .walking, confidence: .high, speed: 1.5,
                                     startedAt: 1000, stepsBefore: 812, distanceBefore: 610)

        let ledger = MotionLedger.resuming(from: published, at: 1010)

        #expect(ledger.steps == 812 + 20)
        #expect(ledger.metres == 610 + 20 * 0.75)
    }

    @Test func `should resume from nothing when no intent was published`() {
        #expect(MotionLedger.resuming(from: nil, at: 1010) == .empty)
    }

    @Test func `should hand its totals to the next leg`() {
        // The banked figures are exactly what the next intent carries, so
        // the dylib adds its own leg on top and never sees a discontinuity.
        let banked = MotionLedger(steps: 21, metres: 15.75)
        let next = banked.intent(kind: .running, confidence: .high, speed: 3.6, startedAt: 2000)
        #expect(next.stepsBefore == 21)
        #expect(next.distanceBefore == 15.75)
        #expect(next.kind == .running)
    }
}
