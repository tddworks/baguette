import Foundation
import Mockable
import Testing
@testable import Baguette

/// The screen-state routes — orientation, shake, status bar — answered for
/// any device through `Devices`, under `/devices/:udid/…` and, for a
/// simulator, its old `/simulators/:udid/…`.
@Suite("Screen-state routes")
struct ScreenStateRoutesTests {

    @Test func `should answer a device under the devices tree and a simulator under its old one`() {
        let paths = Server.deviceRoutes("orientation")

        #expect(paths == ["/devices/:udid/orientation", "/simulators/:udid/orientation"])
        for path in ["/devices/U/orientation", "/simulators/U/orientation"] {
            #expect(Server.udid(inPath: path) == "U", "\(path)")
        }
    }

    @Test func `should refuse to rotate a device that can't turn, naming it`() {
        let host = routeDevices(name: "han's iPhone")

        #expect(Server.applyOrientation(udid: "U", value: "portrait", devices: host)
            == .refused(.unable(ability: "orientation", device: "han's iPhone")))
    }

    @Test func `should refuse to shake a device that isn't running, saying so`() async {
        let host = routeDevices(state: .off) { $0.register(.shake) { MockShake() } }

        #expect(await Server.applyShake(udid: "U", devices: host)
            == .refused(.notReady(device: "iPhone 17", state: .off)))
    }

    @Test func `should rotate the device to a valid orientation`() {
        let orientation = MockOrientation()
        let host = routeDevices { $0.register(.orientation) { orientation } }
        given(orientation).set(.value(.landscapeRight)).willReturn(.delivered)

        #expect(Server.applyOrientation(udid: "U", value: "landscape-right", devices: host) == .ok)
        verify(orientation).set(.value(.landscapeRight)).called(1)
    }

    @Test func `should report an invalid value for an unrecognised orientation spelling`() {
        let host = routeDevices()
        #expect(Server.applyOrientation(udid: "U", value: "sideways", devices: host) == .invalidValue)
    }

    @Test func `should report an unknown device when rotating a device that can't be found`() {
        let host = routeDevices()
        #expect(Server.applyOrientation(udid: "ghost", value: "portrait", devices: host) == .unknownDevice)
    }

    @Test func `should report an unknown device when rotating with an empty udid`() {
        let host = routeDevices()
        #expect(Server.applyOrientation(udid: "", value: "portrait", devices: host) == .unknownDevice)
    }

    @Test func `should report a failed dispatch when the device rejects the orientation change`() {
        let orientation = MockOrientation()
        let host = routeDevices { $0.register(.orientation) { orientation } }
        given(orientation).set(.any).willReturn(.rejected)

        #expect(Server.applyOrientation(udid: "U", value: "portrait", devices: host) == .dispatchFailed)
    }

    @Test func `should report the rotation unconfirmed when the helper times out`() {
        let orientation = MockOrientation()
        let host = routeDevices { $0.register(.orientation) { orientation } }
        given(orientation).set(.any).willReturn(.unconfirmed)

        #expect(Server.applyOrientation(udid: "U", value: "portrait", devices: host) == .unconfirmed)
    }

    @Test func `should shake the device`() async {
        let shake = MockShake()
        let host = routeDevices { $0.register(.shake) { shake } }
        given(shake).shake().willReturn()

        #expect(await Server.applyShake(udid: "U", devices: host) == .ok)
        verify(shake).shake().called(1)
    }

    @Test func `should report an unknown device when shaking a device that can't be found`() async {
        let host = routeDevices()
        #expect(await Server.applyShake(udid: "ghost", devices: host) == .unknownDevice)
    }

    @Test func `should report an unknown device when shaking with an empty udid`() async {
        let host = routeDevices()
        #expect(await Server.applyShake(udid: "", devices: host) == .unknownDevice)
    }

    @Test func `should report a failed dispatch when the shake fails`() async {
        let shake = MockShake()
        let host = routeDevices { $0.register(.shake) { shake } }
        given(shake).shake().willThrow(ShakeError.simctlFailed(status: 1))

        #expect(await Server.applyShake(udid: "U", devices: host) == .dispatchFailed)
    }
}
