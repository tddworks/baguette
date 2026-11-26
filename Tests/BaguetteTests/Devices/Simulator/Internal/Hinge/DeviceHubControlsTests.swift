import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// The hinge and the foldable's orientation move as Device Hub moves them:
/// `DeviceHubControls` plays the hinge slider (`sweep`) and the orientation
/// picker (`orientation`) in the guest.
@Suite("DeviceHubControls")
struct DeviceHubControlsTests {
    private func make() -> (DeviceHubControls, SimctlSpawnSessionTests.Guest) {
        let (session, guest) = SimctlSpawnSessionTests.make(program: "DeviceHubControls")
        return (DeviceHubControls(session: session), guest)
    }

    @Test func `should sweep the hinge slider from one angle to another over the time asked`() throws {
        let (controls, guest) = make()
        try controls.fold(from: 130, to: 0, over: 0.8)
        try controls.fold(from: 0, to: 180, over: 0.5)
        #expect(guest.written == ["sweep 130 0 800\n", "sweep 0 180 500\n"])
    }

    @Test(arguments: [
        (DeviceOrientation.portrait, "portrait"),
        (.portraitUpsideDown, "pud"),
        (.landscapeLeft, "landscape-right"),
        (.landscapeRight, "landscape-left"),
    ])
    func `should turn the orientation picker to its native values`(orientation: DeviceOrientation, native: String) throws {
        let (controls, guest) = make()
        try controls.turn(to: orientation)
        #expect(guest.written == ["orientation \(native)\n"])
        // Measured UIDevice values for the native guest commands. The phone
        // backend sends DeviceOrientation.rawValue directly through Purple.
        let physicalValues: [String: UInt32] = [
            "portrait": 1, "pud": 2, "landscape-left": 3, "landscape-right": 4,
        ]
        #expect(physicalValues[native] == orientation.rawValue)
    }

    // Pose delivery and the hinge routes read the hinge's own errors.
    @Test func `should report the program's failures as the hinge's`() {
        let (controls, guest) = make()
        guest.answer = { _ in ["done 1\n"] }
        #expect(throws: HingeError.toolFailed(status: 1)) { try controls.turn(to: .portrait) }
        guest.answer = { _ in [] }
        #expect(throws: HingeError.toolTimedOut) { try controls.fold(from: 0, to: 130, over: 0) }
        guest.exitOnWrite = 3
        #expect(throws: HingeError.toolStartedLate) { try controls.turn(to: .portraitUpsideDown) }
        let (session, _) = SimctlSpawnSessionTests.make(path: nil)
        #expect(throws: HingeError.toolMissing) { try DeviceHubControls(session: session).fold(from: 0, to: 130, over: 0.5) }
    }

    @Test func `should name DeviceHubControls in the hinge's errors`() {
        #expect(String(describing: HingeError.toolStartedLate)
            == "DeviceHubControls started after its deadline and did nothing; the command was not delivered.")
    }
}
