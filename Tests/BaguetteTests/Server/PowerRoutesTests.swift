import Foundation
import Mockable
import Testing
@testable import Baguette

private struct BootFailed: Error, CustomStringConvertible {
    var description: String { "Unable to boot device in current state: Booted" }
}

/// Boot and shutdown, for any device that can be turned on and off.
@Suite("Power routes")
struct PowerRoutesTests {

    @Test func `should boot a device that can be turned on`() {
        let power = MockPower()
        given(power).turnOn().willReturn()
        let host = routeDevices(state: .off) { $0.register(.power) { power } }

        #expect(Server.applyPower(.boot, udid: "U", devices: host) == .ok)
        verify(power).turnOn().called(1)
    }

    @Test func `should shut a device down`() {
        let power = MockPower()
        given(power).turnOff().willReturn()
        let host = routeDevices { $0.register(.power) { power } }

        #expect(Server.applyPower(.shutdown, udid: "U", devices: host) == .ok)
        verify(power).turnOff().called(1)
    }

    @Test func `should refuse to boot a device that can't be turned on, naming it`() {
        let host = routeDevices(name: "han's iPhone")

        #expect(Server.applyPower(.boot, udid: "U", devices: host)
            == .refused(.unable(ability: "power", device: "han's iPhone")))
    }

    @Test func `should report an unknown device when booting one that can't be found`() {
        #expect(Server.applyPower(.boot, udid: "ghost", devices: routeDevices()) == .unknownDevice)
    }

    @Test func `should say what went wrong when a boot fails`() {
        let power = MockPower()
        given(power).turnOn().willThrow(BootFailed())
        let host = routeDevices { $0.register(.power) { power } }

        #expect(Server.applyPower(.boot, udid: "U", devices: host)
            == .failed("Unable to boot device in current state: Booted"))
    }

    @Test func `should answer a device under the devices tree and a simulator under its old one`() {
        #expect(Server.deviceRoutes("boot") == ["/devices/:udid/boot", "/simulators/:udid/boot"])
        #expect(Server.deviceRoutes("shutdown") == ["/devices/:udid/shutdown", "/simulators/:udid/shutdown"])
    }
}
