import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette orientation` and `hinge` against the devices a test hands them.
@Suite("Pose commands")
struct PoseCommandsTests {

    private func turning(to delivery: PoseDelivery) -> any Devices {
        let orientation = MockOrientation()
        given(orientation).set(.any).willReturn(delivery)
        return routeDevices { $0.register(.orientation) { orientation } }
    }

    private func hinge(angle: Double? = nil, fold: (any Error)? = nil) -> any Devices {
        let hinge = MockHinge()
        given(hinge).angle().willReturn(angle.map(HingeAngle.init(degrees:)))
        if let fold {
            given(hinge).fold(to: .any, over: .any).willThrow(fold)
        } else {
            given(hinge).fold(to: .any, over: .any).willReturn()
        }
        return routeDevices { $0.register(.hinge) { hinge } }
    }

    // MARK: - orientation

    @Test func `should turn the device to the orientation given and say so`() async throws {
        let ran = try await run(try OrientationCommand.parse(["--udid", "U", "landscape-left"]),
                                on: turning(to: .delivered))

        #expect(ran.exit == 0)
        #expect(ran.told == ["Set iPhone 17 → landscape-left"])
    }

    @Test func `should exit 1 when the device rejects the orientation`() async throws {
        let ran = try await run(try OrientationCommand.parse(["--udid", "U", "portrait"]),
                                on: turning(to: .rejected))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Orientation change rejected (event port or guest pose helper unavailable?)"])
    }

    @Test func `should exit 3 when the orientation change is unconfirmed`() async throws {
        let ran = try await run(try OrientationCommand.parse(["--udid", "U", "portrait"]),
                                on: turning(to: .unconfirmed))

        #expect(ran.exit == 3)
        #expect(ran.told == ["Orientation change unconfirmed; read the device state before retrying"])
    }

    @Test func `should exit 1 when the device can't turn`() async throws {
        let ran = try await run(try OrientationCommand.parse(["--udid", "U", "portrait"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do orientation"])
    }

    // MARK: - hinge

    @Test func `should answer the hinge's angle when no pose is given`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U"]), on: hinge(angle: 95))

        #expect(ran.said == [#"{"ok":true,"angleDegrees":95.0}"#])
    }

    @Test func `should answer a null angle when the hinge gives no reading`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U"]), on: hinge())

        #expect(ran.said == [#"{"ok":true,"angleDegrees":null}"#])
    }

    @Test func `should fold the hinge to the pose given and answer its angle`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U", "--pose", "open"]), on: hinge())

        #expect(ran.exit == 0)
        #expect(ran.said == [#"{"ok":true,"angleDegrees":130.0}"#])
    }

    @Test func `should exit 2 naming the poses when the pose is unknown`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U", "--pose", "ajar"]), on: hinge())

        #expect(ran.exit == 2)
        #expect(ran.told == ["unknown pose ajar: expected closed, open or flat"])
    }

    @Test func `should exit 3 when the hinge move is unconfirmed`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U", "--angle", "90"]),
                                on: hinge(fold: HingeError.toolTimedOut))

        #expect(ran.exit == 3)
        #expect(ran.told.first?.hasPrefix("Hinge move unconfirmed:") == true)
    }

    @Test func `should exit 1 when the hinge could not be driven`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U", "--angle", "90"]),
                                on: hinge(fold: HingeError.toolMissing))

        #expect(ran.exit == 1)
        #expect(ran.told.first?.hasPrefix("Hinge could not be driven:") == true)
    }

    @Test func `should exit 1 when the device has no hinge`() async throws {
        let ran = try await run(try HingeCLICommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do hinge"])
    }
}
