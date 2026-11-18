import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("CompanionDevices")
struct CompanionDevicesTests {
    private let hello = TwinHello(
        udid: "U1", name: "Baguette's iPhone", model: "iPhone17,2",
        capabilities: ["motion", "screen"]
    )

    @Test func `should list each connected companion phone as a ready physical device`() throws {
        let phones = LiveCompanionPhones()
        phones.register(hello: hello)

        let device = try #require(CompanionDevices(phones: phones, screens: TwinScreens()).all.first)

        #expect(device.id == "U1")
        #expect(device.name == "Baguette's iPhone")
        #expect(device.kind == DeviceKind(platform: .iOS, reality: .physical, model: "iPhone17,2", hardware: "iPhone17,2"))
        #expect(device.state == .ready)
    }

    @Test func `should show a companion's screen once its video has arrived`() throws {
        let phones = LiveCompanionPhones()
        phones.register(hello: hello)
        let screens = TwinScreens()
        _ = screens.open(udid: "U1")

        let device = try #require(try CompanionDevices(phones: phones, screens: screens).find(id: "U1"))

        #expect(device.abilities.names == ["screen"])
        _ = try device.require(.screen)
    }

    @Test func `should have no screen before the companion sends video`() throws {
        let phones = LiveCompanionPhones()
        phones.register(hello: hello)

        let device = try #require(try CompanionDevices(phones: phones, screens: TwinScreens()).find(id: "U1"))

        #expect(device.abilities.names.isEmpty)
    }
}
