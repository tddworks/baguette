import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("Devices")
struct DevicesTests {
    @Test func `should list every device from every source when sources are combined`() {
        let simulator = device("SIM-1", name: "iPhone 17 Pro")
        let phone = device("00008160-001239C43AA0000A", name: "iPhone 18 Pro Max")
        let devices = CombinedDevices([source(simulator), source(phone)])

        #expect(devices.all.map(\.id) == ["SIM-1", "00008160-001239C43AA0000A"])
    }

    @Test func `should find a device in whichever source knows it`() throws {
        let phone = device("PHONE-1", name: "iPhone 18 Pro Max")
        let devices = CombinedDevices([source(device("SIM-1")), source(phone)])

        #expect(try devices.find(id: "PHONE-1")?.name == "iPhone 18 Pro Max")
    }

    @Test func `should find nothing when no source knows the id`() throws {
        let devices = CombinedDevices([source(device("SIM-1"))])

        #expect(try devices.find(id: "NOPE") == nil)
    }

    @Test func `should refuse an id that two sources claim, never pick one`() {
        let devices = CombinedDevices([source(device("SAME")), source(device("SAME"))])

        #expect(throws: DeviceError.claimedTwice(id: "SAME")) {
            try devices.find(id: "SAME")
        }
    }

    @Test func `should hand back the ability of the device an id names`() throws {
        let location = MockLocation()
        var abilities = AbilityTable(device: "iPhone 17 Pro")
        abilities.register(.location) { location }
        let devices = CombinedDevices([source(device("SIM-1", abilities: abilities))])

        #expect(try devices.require(.location, of: "SIM-1") as AnyObject === location)
    }

    @Test func `should refuse a device id no source knows`() {
        let devices = CombinedDevices([source(device("SIM-1"))])

        #expect(throws: DeviceError.unknown(id: "NOPE")) {
            try devices.require(.location, of: "NOPE")
        }
    }

    @Test func `should refuse an ability that needs a running device while the device is off`() {
        var abilities = AbilityTable(device: "iPhone 17 Pro")
        abilities.register(.input) { MockInput() }
        let devices = CombinedDevices([source(device("SIM-1", state: .off, abilities: abilities))])

        #expect(throws: DeviceError.notReady(device: "iPhone 17 Pro", state: .off)) {
            try devices.require(.input, of: "SIM-1")
        }
    }

    @Test func `should hand back an ability that needs no running device while the device is off`() throws {
        var abilities = AbilityTable(device: "iPhone 17 Pro")
        abilities.register(.lifecycle) { MockLifecycle() }
        let devices = CombinedDevices([source(device("SIM-1", state: .off, abilities: abilities))])

        _ = try devices.require(.lifecycle, of: "SIM-1")
    }

    @Test func `should refuse an ability a device never registered before asking whether it is ready`() {
        let devices = CombinedDevices([source(device("PHONE-1", name: "iPhone 18 Pro Max", state: .off))])

        #expect(throws: DeviceError.unable(ability: "input", device: "iPhone 18 Pro Max")) {
            try devices.require(.input, of: "PHONE-1")
        }
    }

    @Test func `should list each ready physical device as connected, with what it can do`() {
        var abilities = AbilityTable(device: "han's iPhone")
        abilities.register(.screen) { MockScreen() }
        abilities.register(.orientation) { MockOrientation() }
        let phone = device(
            "PHONE-1", name: "han's iPhone",
            kind: DeviceKind(platform: .iOS, reality: .physical, model: "iPhone19,7"),
            abilities: abilities)

        #expect(CombinedDevices([source(phone)]).connectedJSON == #"""
            {"connected":[{"capabilities":["screen","orientation"],"model":"iPhone19,7",\#
            "name":"han's iPhone","udid":"PHONE-1"}]}
            """#)
    }

    @Test func `should leave a phone that isn't ready out of the connected devices`() {
        let unplugged = device(
            "PHONE-2", kind: DeviceKind(platform: .iOS, reality: .physical, model: "iPhone14,3"),
            state: .unavailable(reason: "not connected"))

        #expect(CombinedDevices([source(unplugged)]).connectedJSON == #"{"connected":[]}"#)
    }

    @Test func `should list a physical phone on one line, in a simulator line's order`() {
        let phone = device(
            "PHONE-1", name: "han's iPhone",
            kind: DeviceKind(platform: .iOS, reality: .physical, model: "iPhone19,7"),
            state: .unavailable(reason: "not connected"))

        #expect(phone.json == #"""
            {"udid":"PHONE-1","name":"han's iPhone","state":"unavailable","runtime":"",\#
            "reality":"physical","model":"iPhone19,7"}
            """#)
    }

    @Test func `should list each device's kind, state and abilities`() {
        var abilities = AbilityTable(device: "iPhone 17 Pro")
        abilities.register(.shake) { MockShake() }
        abilities.register(.location) { MockLocation() }
        let simulator = device(
            "SIM-1", name: "iPhone 17 Pro",
            kind: DeviceKind(platform: .iOS, reality: .simulated, model: "iPhone 17 Pro"),
            state: .ready, abilities: abilities)

        #expect(CombinedDevices([source(simulator)]).listJSON == #"""
            {"devices":[{"abilities":["shake","location"],"id":"SIM-1",\#
            "kind":{"model":"iPhone 17 Pro","platform":"iOS","reality":"simulated"},\#
            "name":"iPhone 17 Pro","state":"ready"}]}
            """#)
    }

    @Test func `should say why a device is unavailable when listing it`() {
        let phone = device(
            "PHONE-1", name: "iPhone 18 Pro Max",
            kind: DeviceKind(platform: .iOS, reality: .physical, model: "iPhone19,7"),
            state: .unavailable(reason: "locked"))

        #expect(CombinedDevices([source(phone)]).listJSON == #"""
            {"devices":[{"abilities":[],"id":"PHONE-1",\#
            "kind":{"model":"iPhone19,7","platform":"iOS","reality":"physical"},\#
            "name":"iPhone 18 Pro Max","reason":"locked","state":"unavailable"}]}
            """#)
    }
}

extension DevicesTests {
    private func device(
        _ id: DeviceID,
        name: String = "iPhone 17 Pro",
        kind: DeviceKind = DeviceKind(platform: .iOS, reality: .simulated, model: "iPhone 17 Pro"),
        state: DeviceState = .ready,
        abilities: AbilityTable? = nil
    ) -> MockDevice {
        let device = MockDevice()
        given(device).id.willReturn(id)
        given(device).name.willReturn(name)
        given(device).kind.willReturn(kind)
        given(device).state.willReturn(state)
        given(device).abilities.willReturn(abilities ?? AbilityTable(device: name))
        return device
    }

    private func source(_ devices: MockDevice...) -> MockDevices {
        let source = MockDevices()
        given(source).all.willReturn(devices)
        given(source).find(id: .any).willProduce { id in devices.first { $0.id == id } }
        return source
    }
}
