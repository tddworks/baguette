import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// One screenshot handler for every device, under both trees.
@Suite("Screenshot routes")
struct ScreenshotRoutesTests {

    @Test func `should answer a screenshot under the devices tree and a simulator's old one`() {
        #expect(Server.screenshotRoutes == [
            "/devices/:udid/screenshot.jpg", "/simulators/:udid/screenshot.jpg",
            "/devices/:udid/screenshot.png", "/simulators/:udid/screenshot.png",
        ])
    }
}
