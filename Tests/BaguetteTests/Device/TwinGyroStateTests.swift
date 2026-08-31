import Foundation
import Testing
@testable import Baguette

@Suite("TwinGyroState")
struct TwinGyroStateTests {
    private func upright(heading: Double, t: Double) -> AttitudeSample {
        AttitudeSample(
            attitude: Attitude.rotation(degrees: heading, x: 0, y: 0, z: 1)
                * Attitude.rotation(degrees: 90, x: 1, y: 0, z: 0),
            timestamp: t
        )
    }

    private func flat(yaw: Double, t: Double) -> AttitudeSample {
        AttitudeSample(
            attitude: Attitude.rotation(degrees: yaw, x: 0, y: 0, z: 1), timestamp: t
        )
    }

    private func turnY(_ degrees: Double) -> Attitude {
        Attitude.rotation(degrees: degrees, x: 0, y: 1, z: 0)
    }

    /// Feed a 60 Hz turn: heading 40 + 2° per sample, sender t = 16 ms
    /// steps, arrivals in lockstep at host 100 + t.
    private func feedRamp(_ gyro: TwinGyroState, count: Int) {
        for i in 0...count {
            let t = Double(i) * 0.016
            _ = gyro.add(upright(heading: 40 + Double(i) * 2, t: t), arrivedAt: 100 + t)
        }
    }

    @Test func `the first sample announces`() {
        let gyro = TwinGyroState(zoom: 1)
        #expect(gyro.add(upright(heading: 40, t: 0), arrivedAt: 100) == true)
        #expect(gyro.add(upright(heading: 41, t: 0.016), arrivedAt: 100.016) == false)
    }

    @Test func `poses are absolute against gravity with heading-only calibration`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.add(flat(yaw: 40, t: 0.016), arrivedAt: 100.016)
        _ = gyro.add(flat(yaw: 40, t: 0.032), arrivedAt: 100.032)
        let applied = gyro.pose(at: 100.1)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        ) == true)
    }

    @Test func `ticks replay the true trajectory the delay budget behind`() {
        // Ramp to 60° at t=0.16; clean 16 ms arrivals keep the budget
        // at its 50 ms floor, so the tick at the newest arrival plays
        // t=0.11 → heading 40 + 2·(0.11/0.016) = 53.75 → a 13.75° turn.
        let gyro = TwinGyroState(zoom: 1)
        feedRamp(gyro, count: 10)
        let applied = gyro.pose(at: 100.16)
        #expect(applied?.attitude.isApproximately(turnY(13.75), tolerance: 0.000001) == true)
    }

    @Test func `the clock advances between arrivals`() {
        let gyro = TwinGyroState(zoom: 1)
        feedRamp(gyro, count: 10)
        let applied = gyro.pose(at: 100.19) // playback t=0.14 → 17.5°
        #expect(applied?.attitude.isApproximately(turnY(17.5), tolerance: 0.000001) == true)
    }

    @Test func `a delayed sample never snaps playback backwards`() {
        // Playback holds at the newest sample through a stall; when a
        // late sample lands, a clock rebased on its arrival would point
        // BEHIND the held pose. The monotonic clock shows nothing until
        // playback genuinely passes the hold — never a backward jump.
        let gyro = TwinGyroState(zoom: 1)
        feedRamp(gyro, count: 10) // newest 60° @ t=0.16
        _ = gyro.pose(at: 100.26) // held at the newest → 20° turn shown
        _ = gyro.add(upright(heading: 62, t: 0.176), arrivedAt: 100.30)
        #expect(gyro.pose(at: 100.30) == nil)
    }

    @Test func `a held pose ticks to nothing so a resting phone emits no frames`() {
        let gyro = TwinGyroState(zoom: 1)
        feedRamp(gyro, count: 10)
        #expect(gyro.pose(at: 101) != nil)     // reaches the hold
        #expect(gyro.pose(at: 101.02) == nil)  // held — no scene work
        #expect(gyro.pose(at: 101.04) == nil)
    }

    @Test func `sensor micro-noise stays inside the dead-band`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.pose(at: 100.06)
        _ = gyro.add(upright(heading: 40.001, t: 0.016), arrivedAt: 100.016)
        #expect(gyro.pose(at: 100.08) == nil)
    }

    @Test func `rezero recaptures the heading but never the tilt`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 0, t: 0), arrivedAt: 100)
        gyro.rezero()
        _ = gyro.add(flat(yaw: 77, t: 1), arrivedAt: 101)
        _ = gyro.add(flat(yaw: 77, t: 1.1), arrivedAt: 101.1)
        let applied = gyro.pose(at: 101.4)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        ) == true)
    }

    @Test func `the delay budget adapts to measured arrival jitter`() {
        // Clean 16 ms arrivals: budget at the floor, tick plays 50 ms
        // back — ramp to 90° at t=0.4, playback 0.35 → 43.75° turn.
        let clean = TwinGyroState(zoom: 1)
        feedRamp(clean, count: 25)
        #expect(clean.pose(at: 100.4)?.attitude
            .isApproximately(turnY(43.75), tolerance: 0.00001) == true)

        // A history of 200 ms stalls grows the budget so playback stops
        // underrunning into hold-then-snap: the tick at arrival still
        // plays deep in the buffered past, nowhere near the newest turn.
        let bursty = TwinGyroState(zoom: 1)
        var t = 0.0
        _ = bursty.add(upright(heading: 40, t: t), arrivedAt: 100 + t)
        for _ in 0..<10 {
            t += 0.2
            _ = bursty.add(upright(heading: 40, t: t), arrivedAt: 100 + t)
        }
        t += 0.1
        _ = bursty.add(upright(heading: 50, t: t), arrivedAt: 100 + t)
        #expect(bursty.pose(at: 100 + t)?.attitude
            .isApproximately(turnY(0), tolerance: 0.00001) == true)
    }

    @Test func `quad pushes are throttled by the host clock`() {
        let gyro = TwinGyroState(zoom: 1)
        feedRamp(gyro, count: 25)
        #expect(gyro.pose(at: 100.10)?.pushQuad == true)
        #expect(gyro.pose(at: 100.15)?.pushQuad == false)
        #expect(gyro.pose(at: 100.40)?.pushQuad == true)
    }

    @Test func `zoom updates ride along without disturbing the pose`() {
        let gyro = TwinGyroState(zoom: 1)
        feedRamp(gyro, count: 10)
        gyro.set(zoom: 1.6)
        #expect(gyro.pose(at: 100.16)?.zoom == 1.6)
    }
}
