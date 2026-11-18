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

    @Test func `should read a wire quaternion in CoreMotion x-y-z-w order`() {
        let attitude = Attitude(wire: [0.1, -0.2, 0.3, 0.9])
        #expect(attitude?.x == 0.1)
        #expect(attitude?.y == -0.2)
        #expect(attitude?.z == 0.3)
        #expect(attitude?.w == 0.9)
    }

    @Test func `should reject a wire attitude that is not exactly four numbers`() {
        #expect(Attitude(wire: [0.1, 0.2, 0.3]) == nil)
        #expect(Attitude(wire: [0.1, 0.2, 0.3, 0.9, 1.0]) == nil)
        #expect(Attitude(wire: []) == nil)
    }

    @Test func `should come back to no rotation when an attitude is composed with its inverse`() {
        let q = aboutZ(73)
        #expect((q * q.inverse).isApproximately(.identity))
    }

    @Test func `should read no rotation when re-zeroed against the current pose`() {
        let reference = aboutZ(30)
        #expect(reference.rezeroed(against: reference).isApproximately(.identity))
    }

    @Test func `should measure rotation relative to the reference pose when re-zeroed`() {
        let reference = aboutZ(30)
        let current = aboutZ(75)
        #expect(current.rezeroed(against: reference).isApproximately(aboutZ(45)))
    }

    @Test func `should start at the current attitude and end at the target when interpolating`() {
        let from = aboutZ(0)
        let to = aboutZ(90)
        #expect(from.slerped(toward: to, fraction: 0).isApproximately(from))
        #expect(from.slerped(toward: to, fraction: 1).isApproximately(to))
    }

    @Test func `should halve the rotation at the midpoint of an interpolation`() {
        let from = aboutZ(0)
        let to = aboutZ(90)
        #expect(from.slerped(toward: to, fraction: 0.5).isApproximately(aboutZ(45)))
    }

    @Test func `should interpolate along the shortest path when the sender flips quaternion sign`() {
        // q and -q encode the same attitude; a sender may flip sign
        // between samples. Interpolating naively through the flip swings
        // the model the long way round — the midpoint must still be the
        // small half-rotation.
        let from = aboutZ(0)
        let flipped = aboutZ(10).negated
        #expect(from.slerped(toward: flipped, fraction: 0.5).isApproximately(aboutZ(5)))
    }

    @Test func `should treat a quaternion and its negation as the same attitude`() {
        let q = aboutZ(40)
        #expect(q.isApproximately(q.negated))
    }
}

extension AttitudeTests {
    private func aboutAxis(_ degrees: Double, x: Double, y: Double, z: Double) -> Attitude {
        let half = degrees * .pi / 360
        return Attitude(x: x * sin(half), y: y * sin(half), z: z * sin(half), w: cos(half))
    }

    @Test func `should rotate a vector the way the scene's euler composition does`() {
        // 30° about Y must move a point exactly as the euler projection
        // does — the quaternion quad path and the euler quad path have
        // to agree or Interact clicks drift in gyro mode.
        let q = Attitude(x: 0, y: sin(15 * .pi / 180), z: 0, w: cos(15 * .pi / 180))
        let rotated = q.rotate(Vector3(x: 1, y: 0, z: 0))
        #expect(abs(rotated.x - cos(30 * .pi / 180)) < 0.0001)
        #expect(abs(rotated.y) < 0.0001)
        #expect(abs(rotated.z + sin(30 * .pi / 180)) < 0.0001)
    }

    @Test func `should leave a vector alone under no rotation`() {
        let rotated = Attitude.identity.rotate(Vector3(x: 0.3, y: -0.7, z: 2))
        #expect(abs(rotated.x - 0.3) < 0.0001)
        #expect(abs(rotated.y + 0.7) < 0.0001)
        #expect(abs(rotated.z - 2) < 0.0001)
    }
}

extension AttitudeTests {
    private func flatYawed(_ degrees: Double) -> Attitude {
        Attitude.rotation(degrees: degrees, x: 0, y: 0, z: 1)
    }

    private func uprightFacing(heading: Double) -> Attitude {
        Attitude.rotation(degrees: heading, x: 0, y: 0, z: 1)
            * Attitude.rotation(degrees: 90, x: 1, y: 0, z: 0)
    }

    @Test func `should read the heading as the rotation about gravity`() {
        #expect(abs(flatYawed(30).headingDegrees - 30) < 0.001)
        #expect(abs(uprightFacing(heading: 40).headingDegrees - 40) < 0.001)
        #expect(abs(Attitude.identity.headingDegrees) < 0.001)
    }

    @Test func `should face the stage front when the phone is upright at the captured heading`() {
        let pose = uprightFacing(heading: 25).stagePose(headingDegrees: 25)
        #expect(pose.isApproximately(.identity))
    }

    @Test func `should lay the model flat when the phone lies flat`() {
        // Absolute against gravity: lying on the desk is lying on the
        // stage, whatever heading was captured. -90 about the stage X
        // tips the model onto its back, screen up.
        let pose = flatYawed(50).stagePose(headingDegrees: 50)
        #expect(pose.isApproximately(Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)))
    }

    @Test func `should turn the model about the stage's up axis when the phone turns in place`() {
        let pose = uprightFacing(heading: 25 + 30).stagePose(headingDegrees: 25)
        #expect(pose.isApproximately(Attitude.rotation(degrees: 30, x: 0, y: 1, z: 0)))
    }
}
