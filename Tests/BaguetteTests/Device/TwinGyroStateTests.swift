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
        let applied = gyro.rotation(for: aboutZ(40))
        #expect(applied?.announce == true)
        #expect(abs(applied?.rotation.z ?? 99) < 0.001)
    }

    @Test func `samples are throttled to twenty applies a second`() {
        let (gyro, clock) = make()
        _ = gyro.rotation(for: aboutZ(0))
        clock.now += 0.01
        #expect(gyro.rotation(for: aboutZ(5)) == nil)
        clock.now += 0.05
        #expect(gyro.rotation(for: aboutZ(5)) != nil)
    }

    @Test func `rotation is measured against the auto-zero reference`() {
        let (gyro, clock) = make()
        _ = gyro.rotation(for: aboutZ(30))
        clock.now += 0.1
        let applied = gyro.rotation(for: aboutZ(75))
        #expect(abs((applied?.rotation.z ?? 0) - 45) < 0.001)
    }

    @Test func `rezero captures the next sample as the new front`() {
        let (gyro, clock) = make()
        _ = gyro.rotation(for: aboutZ(0))
        clock.now += 0.1
        gyro.rezero()
        let applied = gyro.rotation(for: aboutZ(60))
        #expect(abs(applied?.rotation.z ?? 99) < 0.001)
    }

    @Test func `tilt is clamped to the stage's eighty-degree bound`() {
        let (gyro, clock) = make()
        _ = gyro.rotation(for: AttitudeSample(attitude: .identity, timestamp: 0))
        clock.now += 0.1
        let half = 100.0 * Double.pi / 360
        let steep = AttitudeSample(
            attitude: Attitude(x: sin(half), y: 0, z: 0, w: cos(half)), timestamp: 0
        )
        let applied = gyro.rotation(for: steep)
        #expect(applied?.rotation.x == 80)
    }

    @Test func `quad pushes are rarer than applies`() {
        let (gyro, clock) = make()
        #expect(gyro.rotation(for: aboutZ(0))?.pushQuad == true)
        clock.now += 0.06
        #expect(gyro.rotation(for: aboutZ(5))?.pushQuad == false)
        clock.now += 0.25
        #expect(gyro.rotation(for: aboutZ(10))?.pushQuad == true)
    }

    @Test func `zoom updates ride along without disturbing the pose`() {
        let (gyro, clock) = make()
        _ = gyro.rotation(for: aboutZ(0))
        gyro.set(zoom: 1.6)
        clock.now += 0.1
        #expect(gyro.rotation(for: aboutZ(0))?.zoom == 1.6)
    }
}
