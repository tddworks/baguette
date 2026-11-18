import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `MotionProfile` — the per-kind constants the
/// injected dylib evaluates to synthesise `CMPedometer` counters and
/// `CMMotionManager` samples.
///
/// The split this type exists to enforce: **policy lives here, in tested
/// Swift; the dylib only does arithmetic.** It cannot be the other way
/// round — a pedometer must accumulate monotonically and `CMMotionManager`
/// delivers at up to 100 Hz, so neither can be streamed from the host.
/// The host publishes the constants; the dylib integrates them.
@Suite("MotionProfile")
struct MotionProfileTests {

    @Test func `should pace a walk at roughly two steps a second`() {
        // 1.4 m/s over a 0.75 m stride ≈ 1.87 steps/s — the familiar
        // human walking cadence, and the browser's `Walk` preset.
        let profile = MotionProfile(kind: .walking, speed: 1.4)
        #expect(abs(profile.cadenceHz - 1.867) < 0.01)
    }

    @Test func `should step faster when the walk is faster`() {
        let slow = MotionProfile(kind: .walking, speed: 1.0)
        let brisk = MotionProfile(kind: .walking, speed: 2.0)
        #expect(brisk.cadenceHz > slow.cadenceHz)
    }

    @Test func `should run with a longer stride than it walks`() {
        #expect(MotionProfile(kind: .running, speed: 3.5).strideMetres
                > MotionProfile(kind: .walking, speed: 1.4).strideMetres)
    }

    @Test func `should take no steps while cycling or driving`() {
        // A pedometer on a bike or in a car does not count pedal strokes
        // as steps, and an app charting daily steps would be wrong if it
        // did. No stride means no cadence, which means no step accrual.
        for kind in [MotionKind.cycling, .automotive] {
            let profile = MotionProfile(kind: kind, speed: 10)
            #expect(profile.strideMetres == 0)
            #expect(profile.cadenceHz == 0)
        }
    }

    @Test func `should take no steps while stationary`() {
        let profile = MotionProfile(kind: .stationary, speed: 0)
        #expect(profile.cadenceHz == 0)
    }

    @Test func `should shake hardest when running and least when still`() {
        // Drives the synthesised accelerometer/gyro amplitude, so the
        // ordering is the whole point: a run must read as more motion
        // than a walk, and a standstill as almost none.
        let still = MotionProfile(kind: .stationary, speed: 0).gaitAmplitude
        let walk = MotionProfile(kind: .walking, speed: 1.4).gaitAmplitude
        let run = MotionProfile(kind: .running, speed: 3.5).gaitAmplitude
        #expect(run > walk)
        #expect(walk > still)
    }

    @Test func `should report no motion at all when the kind is unknown`() {
        // "I don't know" must not be dressed up as synthetic movement.
        let profile = MotionProfile(kind: .unknown, speed: -1)
        #expect(profile.cadenceHz == 0)
        #expect(profile.gaitAmplitude == 0)
    }
}
