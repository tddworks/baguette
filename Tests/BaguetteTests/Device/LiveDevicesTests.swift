import Foundation
import Testing
@testable import Baguette

@Suite("LiveDevices")
struct LiveDevicesTests {
    private let hello = TwinHello(
        udid: "U1", name: "iPhone", model: "iPhone17,2", capabilities: ["motion"]
    )

    @Test func `a registered companion appears in the list`() {
        let devices = LiveDevices()
        devices.register(hello: hello)
        #expect(devices.all == [Device(hello: hello)])
        #expect(devices.find(udid: "U1") != nil)
    }

    @Test func `unregistering removes the device`() {
        let devices = LiveDevices()
        devices.register(hello: hello)
        devices.unregister(udid: "U1")
        #expect(devices.all.isEmpty)
    }

    @Test func `re-registering a udid replaces the earlier identity`() {
        let devices = LiveDevices()
        devices.register(hello: hello)
        devices.register(hello: TwinHello(
            udid: "U1", name: "Renamed", model: "iPhone17,2", capabilities: []
        ))
        #expect(devices.all.count == 1)
        #expect(devices.find(udid: "U1")?.name == "Renamed")
    }

    @Test func `devices list in registration order`() {
        let devices = LiveDevices()
        devices.register(hello: hello)
        devices.register(hello: TwinHello(
            udid: "U2", name: "iPad", model: "iPad16,3", capabilities: []
        ))
        #expect(devices.all.map(\.udid) == ["U1", "U2"])
    }
}
