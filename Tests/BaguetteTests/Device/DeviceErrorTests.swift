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
}
