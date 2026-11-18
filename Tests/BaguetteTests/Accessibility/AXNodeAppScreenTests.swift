import Foundation
import Testing
@testable import Baguette

@Suite("AXNode app screen")
struct AXNodeAppScreenTests {
    @Test func `should take a phone tree's screen from the app that fills it`() {
        let app = AXNode(role: "AXApplication", label: "AirBuild",
                         frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 440, height: 956)))

        #expect(app.onItsAppsScreen.screen == AXScreen(width: 440, height: 956, orientation: .portrait))
    }

    @Test func `should keep a screen the tree already knows`() {
        let known = AXScreen(width: 402, height: 874, orientation: .landscapeLeft)
        let app = AXNode(role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 440, height: 956)),
                         screen: known)

        #expect(app.onItsAppsScreen.screen == known)
    }
}
