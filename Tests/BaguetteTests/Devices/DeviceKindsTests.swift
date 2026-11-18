import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("DeviceKinds")
struct DeviceKindsTests {
    @Test func `should list every kind of device from one list — simulators, companion phones, then phones on a cable`() {
        let simulators = MockSimulators()
        given(simulators).all.willReturn([simulator(udid: "SIM-1")])
        let companions = MockDevices()
        given(companions).all.willReturn([device("COMPANION-1")])
        let phones = MockDevices()
        given(phones).all.willReturn([device("PHONE-1")])

        let kinds = DeviceKinds(simulators: simulators, companions: companions, phones: phones)

        #expect(kinds.devices.all.map(\.id) == ["SIM-1", "COMPANION-1", "PHONE-1"])
    }

    @Test func `should list no companion phones outside serve, where none can connect`() {
        let simulators = MockSimulators()
        given(simulators).all.willReturn([simulator(udid: "SIM-1")])
        let phones = MockDevices()
        given(phones).all.willReturn([device("PHONE-1")])

        let kinds = DeviceKinds(simulators: simulators, phones: phones)

        #expect(kinds.devices.all.map(\.id) == ["SIM-1", "PHONE-1"])
    }
}

private func simulator(udid: String) -> MockSimulator {
    let sim = MockSimulator()
    given(sim).udid.willReturn(udid)
    given(sim).name.willReturn("My iPhone")
    given(sim).state.willReturn(.booted)
    given(sim).runtime.willReturn("iOS 26.4")
    given(sim).deviceTypeName.willReturn("iPhone 17 Pro")
    return sim
}

private func device(_ id: DeviceID) -> MockDevice {
    let device = MockDevice()
    given(device).id.willReturn(id)
    given(device).kind.willReturn(DeviceKind(platform: .iOS, reality: .physical, model: "iPhone19,7"))
    return device
}
