import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

@Suite("SimulatorDevice")
struct SimulatorDeviceTests {
    @Test func `should read a simulator's identity, kind and state as a device's`() {
        let device = SimulatorDevice(simulator(state: .booted))

        #expect(device.id == "SIM-1")
        #expect(device.name == "My iPhone")
        #expect(device.kind == DeviceKind(platform: .iOS, reality: .simulated, model: "iPhone 17 Pro", os: "iOS 26.4"))
        #expect(device.state == .ready)
    }

    @Test(arguments: [
        ("watchOS 12.0", DeviceKind.Platform.watchOS),
        ("tvOS 26.0", .tvOS),
        ("visionOS 26.0", .visionOS),
        ("xrOS 2.0", .visionOS),
    ])
    func `should read a simulator's platform from its runtime`(runtime: String, platform: DeviceKind.Platform) {
        #expect(SimulatorDevice(simulator(runtime: runtime)).kind.platform == platform)
    }

    @Test func `should name a simulator's OS by its runtime`() {
        #expect(SimulatorDevice(simulator(runtime: "iOS 18.2")).kind.os == "iOS 18.2")
    }

    @Test func `should name no OS for a simulator whose runtime the host didn't name`() {
        #expect(SimulatorDevice(simulator(runtime: "")).kind.os == nil)
    }

    @Test func `should read a simulator whose runtime the host didn't name as iOS`() {
        let device = SimulatorDevice(simulator(runtime: ""))

        #expect(device.kind.platform == .iOS)
    }

    @Test func `should play every input role on a screen with one HID, so a keystroke rides the services the gestures warmed`() throws {
        let sim = simulator(state: .booted)
        let made = HIDsMade()
        given(sim).input().willProduce { made.count += 1; return InputMocks() }
        let device = SimulatorDevice(sim)

        let screen = try device.input()
        _ = try screen.require(.touch)
        _ = try screen.require(.press)
        _ = try screen.require(.key)
        _ = try screen.require(.scroll)

        #expect(made.count == 1)
    }

    @Test func `should register every simulator role as an ability`() {
        let device = SimulatorDevice(simulator())

        #expect(device.abilities.names == [
            "power", "screen", "touch", "press", "key", "scroll", "type", "displays", "hinge", "externalDisplays",
            "accessibility", "logs", "orientation", "statusBar", "interface", "location",
            "motion", "network", "inputSurface", "camera", "pasteboard", "apps", "notify", "defaults", "photos", "shake",
            "watchPairing",
        ])
    }

    @Test func `should hand back the simulator's own role for an ability`() throws {
        let sim = simulator()
        let location = MockLocation()
        given(sim).location().willReturn(location)

        let found = try SimulatorDevice(sim).abilities.require(.location)

        #expect(found as AnyObject === location)
    }

    @Test func `should boot the simulator when it is turned on`() throws {
        let sim = simulator()
        given(sim).boot().willReturn()

        try SimulatorDevice(sim).abilities.require(.power).turnOn()

        verify(sim).boot().called(1)
    }

    @Test func `should shut the simulator down when it is turned off`() throws {
        let sim = simulator()
        given(sim).shutdown().willReturn()

        try SimulatorDevice(sim).abilities.require(.power).turnOff()

        verify(sim).shutdown().called(1)
    }
}

@Suite("SimulatorDevices")
struct SimulatorDevicesTests {
    @Test func `should list every simulator as a device`() {
        let simulators = MockSimulators()
        given(simulators).all.willReturn([simulator(udid: "A"), simulator(udid: "B")])

        #expect(SimulatorDevices(simulators).all.map(\.id) == ["A", "B"])
    }

    @Test func `should find a simulator by its udid as a device`() throws {
        let simulators = MockSimulators()
        given(simulators).find(udid: .value("A")).willReturn(simulator(udid: "A"))

        #expect(try SimulatorDevices(simulators).find(id: "A")?.id == "A")
    }

    @Test func `should find nothing when no simulator has the id`() throws {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)

        #expect(try SimulatorDevices(simulators).find(id: "NOPE") == nil)
    }
}

private func simulator(
    udid: String = "SIM-1", state: SimulatorState = .shutdown, runtime: String = "iOS 26.4"
) -> MockSimulator {
    let sim = MockSimulator()
    given(sim).udid.willReturn(udid)
    given(sim).name.willReturn("My iPhone")
    given(sim).state.willReturn(state)
    given(sim).runtime.willReturn(runtime)
    given(sim).deviceTypeName.willReturn("iPhone 17 Pro")
    return sim
}

private final class HIDsMade: @unchecked Sendable {
    var count = 0
}
