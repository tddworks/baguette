import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `MotionSession` — the state behind the
/// motion feature: which kind is being published, what the pedometer has
/// accrued, and whether a location walk is allowed to drive any of it.
///
/// Mirrors `CameraSession`: `@MainActor`, holds the session state, drives
/// one `@Mockable` collaborator, and reports failures through `lastError`
/// rather than throwing at its caller.
@Suite("MotionSession")
@MainActor
struct MotionSessionTests {

    private struct Wiring {
        let session: MotionSession
        let motion: MockMotion
        let sim: MockSimulator
        let clock: Clock
        let captures: Captures
    }

    /// Every intent handed to `publish`, in order — the same capture
    /// pattern `SimctlSimulatorInjectionTests` uses for argv.
    private final class Captures: @unchecked Sendable {
        var intents: [MotionIntent] = []
        var last: MotionIntent? { intents.last }
    }

    /// Test clock — motion accrual is time-based, so the session takes its
    /// "now" as a dependency rather than reading the wall clock.
    private final class Clock: @unchecked Sendable {
        var now: Double = 1000
    }

    private func makeWiring() -> Wiring {
        let motion = MockMotion()
        let captures = Captures()
        given(motion).publish(.any, on: .any).willProduce { intent, _ in
            captures.intents.append(intent)
        }
        given(motion).clear(on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let clock = Clock()
        let session = MotionSession(motion: motion, now: { clock.now })
        return Wiring(session: session, motion: motion, sim: sim, clock: clock,
                      captures: captures)
    }

    @Test func `set publishes the requested kind`() async {
        let w = makeWiring()

        await w.session.set(kind: .walking, confidence: .high, speed: 1.5, on: w.sim)

        #expect(w.session.phase == .publishing(.walking))
        #expect(w.captures.last?.kind == .walking)
        #expect(w.captures.last?.speed == 1.5)
    }

    @Test func `a location walk cannot drive motion while motion is off`() async {
        // Arming rewrites a sim-wide env var and only takes effect on the
        // next app launch, so it must never happen as a silent side effect
        // of moving the device. Motion is opt-in; until it's on, a walk
        // publishes nothing.
        let w = makeWiring()

        await w.session.drive(speed: 1.5, on: w.sim)

        #expect(w.session.phase == .idle)
        verify(w.motion).publish(.any, on: .any).called(0)
    }

    @Test func `a location walk classifies its speed once motion is on`() async {
        let w = makeWiring()
        await w.session.set(kind: .walking, confidence: .high, speed: 1.5, on: w.sim)

        w.clock.now = 1010
        await w.session.drive(speed: 6, on: w.sim)

        #expect(w.session.phase == .publishing(.cycling))
        #expect(w.captures.last?.kind == .cycling)
    }

    @Test func `changing legs banks what the previous leg walked`() async {
        // 10 s of walking at 1.5 m/s over a 0.75 m stride = 20 steps, and
        // the next leg must carry them so an app's daily total keeps
        // climbing instead of restarting.
        let w = makeWiring()
        await w.session.set(kind: .walking, confidence: .high, speed: 1.5, on: w.sim)

        w.clock.now = 1010
        await w.session.drive(speed: 3.6, on: w.sim)

        #expect(w.captures.last?.stepsBefore == 20)
        #expect(w.captures.last?.distanceBefore == 15)
        #expect(w.session.steps == 20)
    }

    @Test func `skips a republish when the speed barely moved`() async {
        // Each publish costs a `launchctl` spawn, and the browser's joystick
        // sends a fresh vector several times a second. 0.1 m/s is the same
        // epsilon `sim-location.js` already throttles its own sends with.
        let w = makeWiring()
        await w.session.set(kind: .walking, confidence: .high, speed: 1.5, on: w.sim)

        w.clock.now = 1005
        await w.session.drive(speed: 1.55, on: w.sim)

        verify(w.motion).publish(.any, on: .any).called(1)
    }

    @Test func `republishes when the kind changes even if the speed barely moved`() async {
        // Crossing a band boundary matters however small the step: an app
        // gating on `stationary` must see the transition.
        let w = makeWiring()
        await w.session.set(kind: .stationary, confidence: .high, speed: 0.15, on: w.sim)

        w.clock.now = 1005
        await w.session.drive(speed: 0.25, on: w.sim)

        #expect(w.captures.last?.kind == .walking)
        verify(w.motion).publish(.any, on: .any).called(2)
    }

    @Test func `stop parks the device as stationary before disarming`() async {
        // An app already running still has the dylib loaded, so the last
        // thing it reads must say "not moving" rather than a stale walk.
        let w = makeWiring()
        await w.session.set(kind: .walking, confidence: .high, speed: 1.5, on: w.sim)

        w.clock.now = 1010
        await w.session.stop()

        #expect(w.session.phase == .idle)
        #expect(w.captures.last?.kind == .stationary)
        verify(w.motion).clear(on: .any).called(1)
    }

    @Test func `stop keeps the totals already walked`() async {
        let w = makeWiring()
        await w.session.set(kind: .walking, confidence: .high, speed: 1.5, on: w.sim)

        w.clock.now = 1010
        await w.session.stop()

        // The parked intent still reports 20 steps: a pedometer that reset
        // to zero on stop would make an app's chart jump backwards.
        #expect(w.captures.last?.stepsBefore == 20)
        #expect(w.session.steps == 20)
    }

    @Test func `stop does nothing when motion was never started`() async {
        let w = makeWiring()

        await w.session.stop()

        verify(w.motion).clear(on: .any).called(0)
        verify(w.motion).publish(.any, on: .any).called(0)
    }

    @Test func `a failed republish does not bank the same leg twice`() async {
        // The leg in flight is banked *before* the new intent is published.
        // If that publish fails, the banked seconds must not be banked again
        // — leaving `startedAt` untouched counted them on every subsequent
        // bank and inflated the step total for the rest of the session (this
        // case produced 60 steps instead of 40).
        //
        // 40 is the honest answer, not 20: a failed publish leaves the device
        // still reporting the previous walk, so it really did keep walking
        // through the second interval and those steps are real.
        let motion = MockMotion()
        let captures = Captures()
        var failNext = false
        given(motion).publish(.any, on: .any).willProduce { intent, _ in
            if failNext { throw SimctlCapture.Failure.failed(udid: "U", status: 2, output: "") }
            captures.intents.append(intent)
        }
        given(motion).clear(on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let clock = Clock()
        let session = MotionSession(motion: motion, now: { clock.now })

        // 10 s of walking at 1.5 m/s = 20 steps, banked by the failed drive.
        await session.set(kind: .walking, confidence: .high, speed: 1.5, on: sim)
        clock.now = 1010
        failNext = true
        await session.drive(speed: 3.6, on: sim)
        failNext = false

        // Another 10 s of that same walk, then a successful publish: 20 steps
        // from before the failure and 20 from after it.
        clock.now = 1020
        await session.set(kind: .running, confidence: .high, speed: 3.6, on: sim)

        #expect(session.steps == 40)
        #expect(captures.last?.stepsBefore == 40)
    }

    @Test func `a failed disarm leaves the device parked, not still walking`() async {
        // `stop` parks the device and then disarms. If the park succeeds and
        // the disarm fails, the published intent is stationary — so a retry
        // must bank *that*, not the walk it replaced. Holding on to the old
        // moving intent added phantom steps for time the device spent parked.
        let motion = MockMotion()
        let captures = Captures()
        given(motion).publish(.any, on: .any).willProduce { intent, _ in
            captures.intents.append(intent)
        }
        given(motion).clear(on: .any).willThrow(SimctlCapture.Failure.failed(udid: "U", status: 2, output: ""))
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let clock = Clock()
        let session = MotionSession(motion: motion, now: { clock.now })

        await session.set(kind: .walking, confidence: .high, speed: 1.5, on: sim)
        clock.now = 1010
        #expect(await session.stop() == false)   // parked, but still armed

        // Ten seconds parked, then a retry. The 20 steps from the walk stand;
        // the parked interval adds none.
        clock.now = 1020
        _ = await session.stop()

        #expect(captures.last?.kind == .stationary)
        #expect(captures.last?.stepsBefore == 20)
    }

    @Test func `a failed publish reports the error and stays off`() async {
        let motion = MockMotion()
        given(motion).publish(.any, on: .any)
            .willThrow(SimctlCapture.Failure.failed(udid: "U", status: 2, output: ""))
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let session = MotionSession(motion: motion, now: { 1000 })

        await session.set(kind: .walking, confidence: .high, speed: 1.5, on: sim)

        #expect(session.phase == .idle)
        #expect(session.lastError != nil)
    }
}
