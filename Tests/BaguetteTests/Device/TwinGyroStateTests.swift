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

    @Test func `the first sample announces and captures the heading only`() {
        // Yaw-only calibration: a phone held upright at any compass
        // heading faces the viewer; its pitch and roll stay absolute.
        let gyro = TwinGyroState(zoom: 1)
        let applied = gyro.pose(for: upright(heading: 40, t: 0), at: 100, interval: 1.0 / 60)
        #expect(applied?.announce == true)
        #expect(applied?.attitude.isApproximately(.identity) == true)
    }

    @Test func `a phone lying flat renders a lying model whatever the heading`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 40, t: 0), at: 100, interval: 1.0 / 60)
        let applied = gyro.pose(for: flat(yaw: 40, t: 0.1), at: 100.1, interval: 1.0 / 60)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        ) == true)
    }

    @Test func `turning in place turns the model about the stage's up axis`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 40, t: 0), at: 100, interval: 1.0 / 60)
        let applied = gyro.pose(for: upright(heading: 70, t: 0.1), at: 100.1, interval: 1.0 / 60)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: 30, x: 0, y: 1, z: 0)
        ) == true)
    }

    @Test func `unchanged poses produce nothing at all`() {
        // "Sync when it's changed": a resting phone means zero scene
        // work and zero pose-driven frames.
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 40, t: 0), at: 100, interval: 1.0 / 60)
        #expect(gyro.pose(for: upright(heading: 40.001, t: 0.1), at: 100.1, interval: 1.0 / 60) == nil)
    }

    @Test func `slow drift accumulates across the dead-band and eventually shows`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 40, t: 0), at: 100, interval: 1.0 / 60)
        var fired = false
        for i in 1...200 {
            let t = Double(i) * 0.05
            if gyro.pose(
                for: upright(heading: 40 + Double(i) * 0.01, t: t),
                at: 100 + t, interval: 1.0 / 60
            ) != nil {
                fired = true
                break
            }
        }
        #expect(fired)
    }

    @Test func `applies are paced to the stream's frame period`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 0, t: 0), at: 100, interval: 1.0 / 30)
        #expect(gyro.pose(for: upright(heading: 20, t: 0.016), at: 100.016, interval: 1.0 / 30) == nil)
        #expect(gyro.pose(for: upright(heading: 20, t: 0.04), at: 100.04, interval: 1.0 / 30) != nil)
    }

    @Test func `rezero recaptures the heading but never the tilt`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 0, t: 0), at: 100, interval: 1.0 / 60)
        gyro.rezero()
        // A lying phone at a new heading right after re-zero: front-
        // facing in yaw, still honestly lying down.
        let applied = gyro.pose(for: flat(yaw: 77, t: 1), at: 101, interval: 1.0 / 60)
        #expect(applied?.attitude.isApproximately(
            Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        ) == true)
    }

    @Test func `quad pushes are throttled by the host clock`() {
        let gyro = TwinGyroState(zoom: 1)
        #expect(gyro.pose(for: upright(heading: 0, t: 0), at: 100, interval: 1.0 / 60)?.pushQuad == true)
        #expect(gyro.pose(for: upright(heading: 10, t: 0.05), at: 100.05, interval: 1.0 / 60)?.pushQuad == false)
        #expect(gyro.pose(for: upright(heading: 20, t: 0.35), at: 100.35, interval: 1.0 / 60)?.pushQuad == true)
    }

    @Test func `zoom updates ride along without disturbing the pose`() {
        let gyro = TwinGyroState(zoom: 1)
        _ = gyro.pose(for: upright(heading: 0, t: 0), at: 100, interval: 1.0 / 60)
        gyro.set(zoom: 1.6)
        let applied = gyro.pose(for: upright(heading: 30, t: 0.1), at: 100.1, interval: 1.0 / 60)
        #expect(applied?.zoom == 1.6)
    }
}
