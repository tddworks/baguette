import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("Devices")
struct DevicesTests {
    private let hello = TwinHello(
        udid: "U1", name: "Baguette's iPhone", model: "iPhone17,2",
        capabilities: ["motion", "screen"]
    )

    @Test func `a device is built from the companion's hello`() {
        let device = Device(hello: hello)
        #expect(device == Device(
            udid: "U1", name: "Baguette's iPhone", model: "iPhone17,2",
            capabilities: ["motion", "screen"]
        ))
    }

    @Test func `find locates a connected device by udid`() {
        let devices = MockDevices()
        given(devices).all.willReturn([Device(hello: hello)])
        #expect(devices.find(udid: "U1")?.name == "Baguette's iPhone")
        #expect(devices.find(udid: "nope") == nil)
    }

    @Test func `listJSON projects the connected devices with sorted keys`() {
        let devices = MockDevices()
        given(devices).all.willReturn([Device(hello: hello)])
        #expect(devices.listJSON == """
        {"connected":[{"capabilities":["motion","screen"],"model":"iPhone17,2","name":"Baguette's iPhone","udid":"U1"}]}
        """)
    }

    @Test func `listJSON with no companions is an empty connected list`() {
        let devices = MockDevices()
        given(devices).all.willReturn([])
        #expect(devices.listJSON == #"{"connected":[]}"#)
    }
}
