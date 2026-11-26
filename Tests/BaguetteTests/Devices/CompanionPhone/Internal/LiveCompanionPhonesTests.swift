import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

@Suite("LiveCompanionPhones")
struct LiveCompanionPhonesTests {
    private let hello = TwinHello(
        udid: "U1", name: "iPhone", model: "iPhone17,2", capabilities: ["motion"]
    )

    @Test func `should list a companion once it registers`() {
        let devices = LiveCompanionPhones()
        devices.register(hello: hello)
        #expect(devices.all == [CompanionPhone(hello: hello)])
        #expect(devices.find(udid: "U1") != nil)
    }

    @Test func `should drop a device from the list when it unregisters`() {
        let devices = LiveCompanionPhones()
        devices.register(hello: hello)
        devices.unregister(udid: "U1")
        #expect(devices.all.isEmpty)
    }

    @Test func `should replace the earlier identity when a udid registers again`() {
        let devices = LiveCompanionPhones()
        devices.register(hello: hello)
        devices.register(hello: TwinHello(
            udid: "U1", name: "Renamed", model: "iPhone17,2", capabilities: []
        ))
        #expect(devices.all.count == 1)
        #expect(devices.find(udid: "U1")?.name == "Renamed")
    }

    @Test func `should list devices in registration order`() {
        let devices = LiveCompanionPhones()
        devices.register(hello: hello)
        devices.register(hello: TwinHello(
            udid: "U2", name: "iPad", model: "iPad16,3", capabilities: []
        ))
        #expect(devices.all.map(\.udid) == ["U1", "U2"])
    }
}

extension LiveCompanionPhonesTests {
    @Test func `should keep a device listed while any of its sockets is connected`() {
        let devices = LiveCompanionPhones()
        let hello = TwinHello(udid: "U9", name: "iPhone", model: "iPhone14,3", capabilities: [])
        devices.register(hello: hello)   // video socket
        devices.register(hello: hello)   // motion socket
        devices.unregister(udid: "U9")   // one closes
        #expect(devices.find(udid: "U9") != nil)
        devices.unregister(udid: "U9")   // both closed
        #expect(devices.find(udid: "U9") == nil)
    }
}
