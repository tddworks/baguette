import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

@Suite("SimulatorOrientation")
struct SimulatorOrientationTests {
    @Test func `should reject a rotation when the panel configuration is unknown`() {
        let orientation = SimulatorOrientation(
            isFoldable: { throw HingeError.toolMissing },
            motor: MockHingeMotor(), standard: MockOrientation()
        )
        #expect(orientation.set(.portrait) == .rejected)
    }

    @Test(arguments: DeviceOrientation.allCases)
    func `should rotate a foldable through its hinge`(_ target: DeviceOrientation) {
        let motor = MockHingeMotor()
        given(motor).turn(to: .value(target)).willReturn()
        let orientation = SimulatorOrientation(
            isFoldable: { true }, motor: motor, standard: MockOrientation()
        )
        #expect(orientation.set(target) == .delivered)
    }

    @Test func `should report the legacy orientation result when the device is not foldable`() {
        let standard = MockOrientation()
        given(standard).set(.value(.landscapeLeft)).willReturn(.delivered)
        given(standard).set(.value(.portrait)).willReturn(.rejected)
        let orientation = SimulatorOrientation(
            isFoldable: { false }, motor: MockHingeMotor(), standard: standard
        )
        #expect(orientation.set(.landscapeLeft) == .delivered)
        #expect(orientation.set(.portrait) == .rejected)
    }

    @Test func `should reject a rotation when a foldable's hinge fails rather than fall back to the legacy path`() {
        let motor = MockHingeMotor()
        given(motor).turn(to: .any).willThrow(HingeError.toolMissing)
        let orientation = SimulatorOrientation(
            isFoldable: { true }, motor: motor, standard: MockOrientation()
        )
        #expect(orientation.set(.portrait) == .rejected)
    }

    /// The helper was stopped after its deadline: the rotation may have
    /// landed, and will not land later. Neither success nor rejection.
    @Test func `should leave a foldable rotation unconfirmed rather than rejected when the hinge helper times out`() {
        let motor = MockHingeMotor()
        given(motor).turn(to: .any).willThrow(HingeError.toolTimedOut)
        let orientation = SimulatorOrientation(
            isFoldable: { true }, motor: motor, standard: MockOrientation()
        )
        #expect(orientation.set(.landscapeLeft) == .unconfirmed)
    }
}
