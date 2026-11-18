import Foundation
import Mockable
import Testing
@testable import Baguette

/// The logs socket for any device: it stops at once, saying why, for a
/// device that has no log stream.
@Suite("Logs route")
struct LogsRouteTests {

    @Test func `should stop the logs of a device that has none, naming it`() {
        #expect(Server.logsStopped(udid: "U", devices: routeDevices(name: "han's iPhone"))
            == #"{"type":"log_stopped","reason":"han's iPhone can't do logs"}"#)
    }

    @Test func `should stop the logs of an unknown device`() {
        #expect(Server.logsStopped(udid: "nope", devices: routeDevices())
            == #"{"type":"log_stopped","reason":"unknown udid"}"#)
    }

    @Test func `should keep the logs of a device that has a log stream going`() {
        let host = routeDevices { $0.register(.logs) { MockLogStream() } }

        #expect(Server.logsStopped(udid: "U", devices: host) == nil)
    }

    @Test func `should answer the logs socket under the devices tree and a simulator's old one`() {
        #expect(Server.deviceRoutes("logs") == ["/devices/:udid/logs", "/simulators/:udid/logs"])
    }
}
