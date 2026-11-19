import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The old `/simulators/:udid/…` spelling still answers, but says it is
/// deprecated and where its successor is.
@Suite("Simulator tree deprecation")
struct DeprecationTests {

    @Test func `should name the devices route that replaces an old per-device one`() {
        #expect(Server.successor(of: "/simulators/U/status-bar") == "/devices/U/status-bar")
        #expect(Server.successor(of: "/simulators/U/chrome-button/power.png") == "/devices/U/chrome-button/power.png")
    }

    @Test func `should deprecate no page and no list`() {
        #expect(Server.successor(of: "/simulators") == nil)
        #expect(Server.successor(of: "/simulators.json") == nil)
        #expect(Server.successor(of: "/simulators/U") == nil)
        #expect(Server.successor(of: "/devices/U/status-bar") == nil)
    }
}
