import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Location, motion and network for any device: a device without the
/// ability is refused by name, and every route answers under both trees.
@Suite("Place routes")
@MainActor
struct PlaceRoutesTests {

    @Test func `should answer a device under the devices tree and a simulator under its old one`() {
        for leaf in ["location", "motion", "network"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }

    @Test func `should refuse to place a device that can't be placed, naming it`() async {
        let host = routeDevices(name: "han's iPhone")

        #expect(await Server.applyLocation(udid: "U", body: #"{"latitude":1,"longitude":2}"#, devices: host)
            == .refused(.unable(ability: "location", device: "han's iPhone")))
    }

    @Test func `should refuse to arm motion on a device that has none, naming it`() async {
        let host = routeDevices(name: "han's iPhone")

        #expect(await Server.applyMotion(udid: "U", body: #"{"activity":"walking"}"#,
                                         devices: host, sessions: MotionSessions())
            == .refused(.unable(ability: "motion", device: "han's iPhone")))
    }

    @Test func `should refuse to condition the network of a device that can't be conditioned, naming it`() async {
        let host = routeDevices(name: "han's iPhone")

        #expect(await Server.applyNetwork(udid: "U", body: #"{"profile":"edge"}"#, devices: host)
            == .refused(.unable(ability: "network", device: "han's iPhone")))
    }

    @Test func `should refuse to read the network of a device that can't be conditioned, naming it`() async {
        let host = routeDevices(name: "han's iPhone")

        await #expect(throws: DeviceError.unable(ability: "network", device: "han's iPhone")) {
            try await Server.networkStateJSON(udid: "U", devices: host)
        }
    }
}
