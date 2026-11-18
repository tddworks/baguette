import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette shake` against the devices a test hands it.
@Suite("Shake command")
struct ShakeCommandTests {

    @Test func `should shake the device the udid names and say so`() async throws {
        let shake = MockShake()
        given(shake).shake().willReturn()

        let ran = try await run(try ShakeCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.shake) { shake } })

        #expect(ran.exit == 0)
        #expect(ran.told == ["Shook iPhone 17"])
    }

    @Test func `should exit 1 naming the udid when no device has it`() async throws {
        let ran = try await run(try ShakeCommand.parse(["--udid", "NOPE"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Device NOPE not found"])
    }

    @Test func `should exit 1 when the device can't shake`() async throws {
        let ran = try await run(try ShakeCommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do shake"])
    }

    @Test func `should exit 1 saying why when the shake fails`() async throws {
        let shake = MockShake()
        given(shake).shake().willThrow(DeviceError.unknown(id: "U"))

        let ran = try await run(try ShakeCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.shake) { shake } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["shake failed: Device U not found"])
    }
}
