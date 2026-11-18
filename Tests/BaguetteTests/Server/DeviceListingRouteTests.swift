import Foundation
import Mockable
import Testing
@testable import Baguette

/// One device as the page reads it: who it is, what kind, its state, and
/// what it can do — so the page shows only what the device can do.
@Suite("Device listing route")
struct DeviceListingRouteTests {

    @Test func `should list a device with the abilities the page shows controls for`() throws {
        let host = routeDevices(name: "iPhone 17") {
            $0.register(.touch) { MockTouch() }
            $0.register(.orientation) { MockOrientation() }
        }

        let json = try #require(Server.deviceListingJSON(udid: "U", devices: host))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(object["name"] as? String == "iPhone 17")
        #expect(object["abilities"] as? [String] == ["touch", "orientation"])
    }

    @Test func `should list no device for an id nobody knows`() {
        #expect(Server.deviceListingJSON(udid: "ghost", devices: routeDevices()) == nil)
    }

    @Test func `should answer the listing under the devices tree and a simulator's old one`() {
        #expect(Server.deviceRoutes("device.json") == ["/devices/:udid/device.json", "/simulators/:udid/device.json"])
    }
}
