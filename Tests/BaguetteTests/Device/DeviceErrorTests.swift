import Testing
@testable import Baguette

@Suite("DeviceError")
struct DeviceErrorTests {
    @Test func `should name the device and the ability it can't do`() {
        #expect("\(DeviceError.unable(ability: "lifecycle", device: "iPhone 18 Pro Max"))"
            == "iPhone 18 Pro Max can't do lifecycle")
    }

    @Test func `should name the id no source knows`() {
        #expect("\(DeviceError.unknown(id: "NOPE"))" == "Device NOPE not found")
    }

    @Test func `should name the id two sources claim`() {
        #expect("\(DeviceError.claimedTwice(id: "SAME"))" == "Device SAME is claimed by two sources")
    }

    @Test func `should say a shut-down device is not booted`() {
        #expect("\(DeviceError.notReady(device: "iPhone 17 Pro", state: .off))"
            == "Device iPhone 17 Pro is not booted")
    }

    @Test func `should say a device is still starting`() {
        #expect("\(DeviceError.notReady(device: "iPhone 17 Pro", state: .starting))"
            == "Device iPhone 17 Pro is still starting")
    }

    @Test func `should say why a device is unavailable`() {
        #expect("\(DeviceError.notReady(device: "iPhone 18 Pro Max", state: .unavailable(reason: "not connected")))"
            == "Device iPhone 18 Pro Max is unavailable: not connected")
    }

    @Test func `should need a running device for an ability that drives its screen`() {
        #expect(Ability<any Screen>.screen.needsReady)
        #expect(Ability<any Input>.input.needsReady)
        #expect(Ability<any Displays>.displays.needsReady)
        #expect(Ability<any Hinge>.hinge.needsReady)
        #expect(Ability<any Orientation>.orientation.needsReady)
        #expect(Ability<any Shake>.shake.needsReady)
        #expect(Ability<any Accessibility>.accessibility.needsReady)
    }

    @Test func `should not need a running device to boot it`() {
        #expect(!Ability<any Lifecycle>.lifecycle.needsReady)
    }
}
