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

    @Test func `the first sample announces`() {
        let gyro = TwinGyroState(zoom: 1)
        #expect(gyro.add(upright(heading: 40, t: 0), arrivedAt: 100) == true)
        #expect(gyro.add(upright(heading: 41, t: 0.016), arrivedAt: 100.016) == false)
    }

    @Test func `poses are absolute against gravity with heading-only calibration`() {
        // Lay the phone down and the model lies down, whatever compass
        // heading was captured.
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.add(flat(yaw: 40, t: 0.1), arrivedAt: 100.1)
        _ = gyro.add(flat(yaw: 40, t: 0.2), arrivedAt: 100.2)
        let applied = gyro.pose(at: 100.3)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        ) == true)
    }

    @Test func `ticks replay the true trajectory a fixed delay behind`() {
        // Turn from heading 40 to 50 between t=0 and t=0.1; the tick
        // at the second arrival plays t=0.05 — exactly half the turn.
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.add(upright(heading: 50, t: 0.1), arrivedAt: 100.1)
        let applied = gyro.pose(at: 100.1)
        #expect(applied?.attitude.isApproximately(turnY(5), tolerance: 0.000001) == true)
    }

    @Test func `the clock advances between arrivals`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.add(upright(heading: 50, t: 0.1), arrivedAt: 100.1)
        let applied = gyro.pose(at: 100.13)
        #expect(applied?.attitude.isApproximately(turnY(8), tolerance: 0.000001) == true)
    }

    @Test func `playback never runs backward when a delayed sample arrives`() {
        // The regression that made interpolation feel broken once: a
        // clock rebased on each arrival computes a playback time BEHIND
        // the shown pose when a sample lands late, snapping the model
        // backwards on every jitter burst.
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.add(upright(heading: 50, t: 0.016), arrivedAt: 100.016)
        _ = gyro.pose(at: 100.10) // held at the newest (full turn)
        _ = gyro.add(upright(heading: 60, t: 0.032), arrivedAt: 100.12)
        let applied = gyro.pose(at: 100.121)
        #expect(applied?.attitude.isApproximately(turnY(20), tolerance: 0.001) == true)
    }

    @Test func `a held pose ticks to nothing so a resting phone emits no frames`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.add(upright(heading: 50, t: 0.1), arrivedAt: 100.1)
        #expect(gyro.pose(at: 101) != nil)     // reaches the hold
        #expect(gyro.pose(at: 101.02) == nil)  // held — no scene work
        #expect(gyro.pose(at: 101.04) == nil)
    }

    @Test func `sensor micro-noise stays inside the dead-band`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = gyro.pose(at: 100.06)
        _ = gyro.add(upright(heading: 40.001, t: 0.1), arrivedAt: 100.1)
        #expect(gyro.pose(at: 100.16) == nil)
    }

    @Test func `rezero recaptures the heading but never the tilt`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 0, t: 0), arrivedAt: 100)
        gyro.rezero()
        _ = gyro.add(flat(yaw: 77, t: 1), arrivedAt: 101)
        _ = gyro.add(flat(yaw: 77, t: 1.1), arrivedAt: 101.1)
        let applied = gyro.pose(at: 101.2)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        ) == true)
    }

    @Test func `the delay budget adapts to measured arrival jitter`() {
        // Clean 16 ms arrivals keep the budget small; a history of
        // 200 ms bursts must grow it so playback stops underrunning
        // into hold-then-snap cycles. Sized by measurement, not feel.
        let clean = TwinGyroState(zoom: 1)
        _ = clean.add(upright(heading: 40, t: 0), arrivedAt: 100)
        _ = clean.add(upright(heading: 50, t: 0.1), arrivedAt: 100.1)
        let cleanPose = clean.pose(at: 100.1)
        #expect(cleanPose?.attitude.isApproximately(turnY(5), tolerance: 0.000001) == true)

        let bursty = TwinGyroState(zoom: 1)
        var t = 0.0
        var host = 100.0
        _ = bursty.add(upright(heading: 40, t: t), arrivedAt: host)
        for _ in 0..<10 { // repeated 200 ms stalls teach the buffer
            t += 0.2; host += 0.2
            _ = bursty.add(upright(heading: 40, t: t), arrivedAt: host)
        }
        t += 0.1; host += 0.1
        _ = bursty.add(upright(heading: 50, t: t), arrivedAt: host)
        // With a grown budget (≥200 ms), the tick at arrival still
        // plays inside the buffered past — nowhere near the newest
        // sample's half-turn point.
        let burstyPose = bursty.pose(at: host)
        #expect(burstyPose?.attitude.isApproximately(turnY(0), tolerance: 0.00001) == true)
    }

    @Test func `quad pushes are throttled by the host clock`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 0, t: 0), arrivedAt: 100)
        _ = gyro.add(upright(heading: 30, t: 1), arrivedAt: 101)
        #expect(gyro.pose(at: 100.5)?.pushQuad == true)
        #expect(gyro.pose(at: 100.55)?.pushQuad == false)
        #expect(gyro.pose(at: 100.85)?.pushQuad == true)
    }

    @Test func `zoom updates ride along without disturbing the pose`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.add(upright(heading: 0, t: 0), arrivedAt: 100)
        _ = gyro.add(upright(heading: 30, t: 0.1), arrivedAt: 100.1)
        gyro.set(zoom: 1.6)
        #expect(gyro.pose(at: 100.1)?.zoom == 1.6)
    }
}
