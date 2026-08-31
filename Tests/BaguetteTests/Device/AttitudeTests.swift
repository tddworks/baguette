import Foundation
import Testing
@testable import Baguette

@Suite("Attitude")
struct AttitudeTests {
    /// Rotation of `degrees` about the device's z axis, the handiest
    /// non-trivial unit quaternion to reason about in tests.
    private func aboutZ(_ degrees: Double) -> Attitude {
        let half = degrees * .pi / 360
        return Attitude(x: 0, y: 0, z: sin(half), w: cos(half))
    }

    @Test func `parses wire quaternions in CoreMotion x-y-z-w order`() {
        let attitude = Attitude(wire: [0.1, -0.2, 0.3, 0.9])
        #expect(attitude?.x == 0.1)
        #expect(attitude?.y == -0.2)
        #expect(attitude?.z == 0.3)
        #expect(attitude?.w == 0.9)
    }

    @Test func `rejects wire payloads that are not exactly four numbers`() {
        #expect(Attitude(wire: [0.1, 0.2, 0.3]) == nil)
        #expect(Attitude(wire: [0.1, 0.2, 0.3, 0.9, 1.0]) == nil)
        #expect(Attitude(wire: []) == nil)
    }

    @Test func `an attitude composed with its inverse is the identity`() {
        let q = aboutZ(73)
        #expect((q * q.inverse).isApproximately(.identity))
    }

    @Test func `re-zeroing against the current pose yields the identity`() {
        let reference = aboutZ(30)
        #expect(reference.rezeroed(against: reference).isApproximately(.identity))
    }

    @Test func `re-zeroing measures rotation relative to the reference pose`() {
        let reference = aboutZ(30)
        let current = aboutZ(75)
        #expect(current.rezeroed(against: reference).isApproximately(aboutZ(45)))
    }

    @Test func `slerp endpoints are self and target`() {
        let from = aboutZ(0)
        let to = aboutZ(90)
        #expect(from.slerped(toward: to, fraction: 0).isApproximately(from))
        #expect(from.slerped(toward: to, fraction: 1).isApproximately(to))
    }

    @Test func `slerp midpoint halves the rotation`() {
        let from = aboutZ(0)
        let to = aboutZ(90)
        #expect(from.slerped(toward: to, fraction: 0.5).isApproximately(aboutZ(45)))
    }

    @Test func `slerp takes the shortest path when the sender flips quaternion sign`() {
        // q and -q encode the same attitude; a sender may flip sign
        // between samples. Interpolating naively through the flip swings
        // the model the long way round — the midpoint must still be the
        // small half-rotation.
        let from = aboutZ(0)
        let flipped = aboutZ(10).negated
        #expect(from.slerped(toward: flipped, fraction: 0.5).isApproximately(aboutZ(5)))
    }

    @Test func `approximate equality treats q and negated q as the same attitude`() {
        let q = aboutZ(40)
        #expect(q.isApproximately(q.negated))
    }
}

extension AttitudeTests {
    private func aboutAxis(_ degrees: Double, x: Double, y: Double, z: Double) -> Attitude {
        let half = degrees * .pi / 360
        return Attitude(x: x * sin(half), y: y * sin(half), z: z * sin(half), w: cos(half))
    }

    @Test func `single-axis rotations convert to euler degrees on their own axis`() {
        let pitch = aboutAxis(30, x: 1, y: 0, z: 0).eulerDegrees
        #expect(abs(pitch.x - 30) < 0.001 && abs(pitch.y) < 0.001 && abs(pitch.z) < 0.001)
        let yaw = aboutAxis(45, x: 0, y: 1, z: 0).eulerDegrees
        #expect(abs(yaw.y - 45) < 0.001 && abs(yaw.x) < 0.001 && abs(yaw.z) < 0.001)
        let roll = aboutAxis(-60, x: 0, y: 0, z: 1).eulerDegrees
        #expect(abs(roll.z + 60) < 0.001 && abs(roll.x) < 0.001 && abs(roll.y) < 0.001)
    }

    @Test func `the identity attitude is zero euler`() {
        let euler = Attitude.identity.eulerDegrees
        #expect(abs(euler.x) < 0.001 && abs(euler.y) < 0.001 && abs(euler.z) < 0.001)
    }
}
