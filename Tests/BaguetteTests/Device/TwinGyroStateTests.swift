import Foundation
import Testing
@testable import Baguette

@Suite("TwinGyroState")
struct TwinGyroStateTests {
    final class Clock: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    private func aboutZ(_ degrees: Double) -> AttitudeSample {
        let half = degrees * .pi / 360
        return AttitudeSample(
            attitude: Attitude(x: 0, y: 0, z: sin(half), w: cos(half)), timestamp: 0
        )
    }

    private func make() -> (TwinGyroState, Clock) {
        let clock = Clock()
        return (TwinGyroState(zoom: 1, now: { clock.now }), clock)
    }

    @Test func `the first sample auto-zeroes and announces`() {
        let (gyro, _) = make()
        let applied = gyro.pose(for: aboutZ(40))
        #expect(applied?.announce == true)
        #expect(applied?.attitude.isApproximately(.identity) == true)
    }

    @Test func `applies run at sample rate with only a jitter guard`() {
        // The stream renders at 60 fps and samples arrive at 60 Hz —
        // the guard only absorbs bursts, never paces below the render.
        let (gyro, clock) = make()
        _ = gyro.pose(for: aboutZ(0))
        clock.now += 0.005
        #expect(gyro.pose(for: aboutZ(5)) == nil)
        clock.now += 0.012
        #expect(gyro.pose(for: aboutZ(5)) != nil)
    }

    @Test func `the pose glides toward the target instead of snapping`() {
        // PhoneTwin's discipline: samples move a TARGET; the displayed
        // pose slerps toward it a fraction per apply, so motion is
        // butter at render rate rather than 30 Hz steps.
        let (gyro, clock) = make()
        _ = gyro.pose(for: aboutZ(0))
        clock.now += 0.1
        let applied = gyro.pose(for: aboutZ(40))
        let expected = Attitude.identity.slerped(
            toward: Attitude(x: 0, y: 0, z: sin(40 * .pi / 360), w: cos(40 * .pi / 360)),
            fraction: 0.25
        )
        #expect(applied?.attitude.isApproximately(expected) == true)
    }

    @Test func `the pose converges on a held target`() {
        let (gyro, clock) = make()
        _ = gyro.pose(for: aboutZ(0))
        let target = aboutZ(40)
        for _ in 0..<80 {
            clock.now += 0.02
            _ = gyro.pose(for: target)
        }
        clock.now += 0.02
        #expect(gyro.pose(for: target)?.attitude
            .isApproximately(target.attitude, tolerance: 0.0001) == true)
    }

    @Test func `rezero captures the next sample as the new front`() {
        let (gyro, clock) = make()
        _ = gyro.pose(for: aboutZ(0))
        clock.now += 0.1
        gyro.rezero()
        let applied = gyro.pose(for: aboutZ(60))
        #expect(applied?.attitude.isApproximately(.identity) == true)
    }

    @Test func `quad pushes are rarer than applies`() {
        let (gyro, clock) = make()
        #expect(gyro.pose(for: aboutZ(0))?.pushQuad == true)
        clock.now += 0.02
        #expect(gyro.pose(for: aboutZ(5))?.pushQuad == false)
        clock.now += 0.25
        #expect(gyro.pose(for: aboutZ(10))?.pushQuad == true)
    }

    @Test func `zoom updates ride along without disturbing the pose`() {
        let (gyro, clock) = make()
        _ = gyro.pose(for: aboutZ(0))
        gyro.set(zoom: 1.6)
        clock.now += 0.1
        #expect(gyro.pose(for: aboutZ(0))?.zoom == 1.6)
    }
}
