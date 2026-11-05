import Testing
import Foundation
@testable import Baguette

/// `describe-ui` already knows where everything is, so it hands the agent the
/// finished command. Like an asc-cli affordance, it's state-aware: an element
/// only offers what will work right now.
@Suite("AXNode affordances")
struct AXAffordanceTests {
    private static let cli = AXAffordance.Style.commandLine(program: "baguette", udid: "X", deviceSet: nil)

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    private func tree(_ children: AXNode...) -> AXNode {
        AXNode(
            role: "AXApplication", label: "Skylark", frame: rect(0, 0, 402, 874), children: children,
            screen: AXScreen(width: 402, height: 874, orientation: .portrait))
    }

    private func rendered(_ tree: AXNode, style: AXAffordance.Style = cli) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(tree.json(affordances: style).utf8))
        return try #require(object as? [String: Any])
    }

    /// The top-level map, without what the root always offers.
    private func offers(_ children: AXNode..., style: AXAffordance.Style = cli) throws -> [String: Any] {
        let root = AXNode(
            role: "AXApplication", label: "Skylark", frame: rect(0, 0, 402, 874), children: children,
            screen: AXScreen(width: 402, height: 874, orientation: .portrait))
        var map = try #require(try rendered(root, style: style)["affordances"] as? [String: Any])
        map["home"] = nil
        map["screenshot"] = nil
        return map
    }

    @Test func `should offer a ready tap on an enabled control on screen`() throws {
        let search = AXNode(role: "AXButton", label: "Search flights", frame: rect(28, 421, 346, 58))

        #expect(try offers(search)["tap Search flights"] as? String
            == "baguette tap --udid X --x 201 --y 450 --width 402 --height 874 --then-describe-ui")
    }

    @Test func `should offer no tap on a disabled element`() throws {
        let pay = AXNode(role: "AXButton", label: "Pay $1,240", frame: rect(16, 717, 370, 58), enabled: false)

        #expect(try offers(pay).isEmpty)
    }

    @Test func `should offer no tap on an element off screen`() throws {
        for frame in [rect(48, 1000, 46, 40), rect(-200, 100, 46, 40)] {
            #expect(try offers(AXNode(role: "AXButton", label: "Seat", frame: frame)).isEmpty)
        }
    }

    @Test func `should offer no tap on a hidden element or one with no size`() throws {
        #expect(try offers(AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40), hidden: true)).isEmpty)
        #expect(try offers(AXNode(role: "AXButton", label: "B", frame: rect(10, 10, 0, 0))).isEmpty)
    }

    @Test func `should offer no tap on text, images or containers because their role doesn't say they respond`() throws {
        for role in ["AXStaticText", "AXImage", "AXGroup", "AXHeading"] {
            #expect(try offers(AXNode(role: role, label: "Text", frame: rect(0, 0, 40, 40))).isEmpty)
        }
    }

    @Test func `should tap near the left of a wide row whose label has several parts`() throws {
        let row = AXNode(role: "AXButton", label: "Orbit 3, 10h 10m, $1,240", frame: rect(16, 514, 370, 72))

        #expect(try offers(row)["tap Orbit 3, 10h 10m, $1,240"] as? String
            == "baguette tap --udid X --x 56 --y 550 --width 402 --height 874 --then-describe-ui")
    }

    @Test func `should tap the centre of a narrow element whose label has several parts`() throws {
        let chip = AXNode(role: "AXButton", label: "Paris, France", frame: rect(0, 0, 100, 40))

        #expect(try (offers(chip)["tap Paris, France"] as? String)?.contains("--x 50 --y 20") == true)
    }

    @Test func `should tap the visible part of an element hanging off the screen`() throws {
        let row = AXNode(role: "AXButton", label: "Smart Invert", frame: rect(36, 860, 100, 28))

        #expect(try (offers(row)["tap Smart Invert"] as? String)?.contains("--x 86 --y 867") == true)
    }

    @Test func `should offer typing only on a focused text field`() throws {
        let focused = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44), focused: true)
        let idle = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44))

        #expect(try offers(focused)["type City"] as? String == #"baguette type --udid X --text "<text>""#)
        #expect(try offers(idle)["type City"] == nil)
        #expect(try offers(idle)["tap City"] != nil)
    }

    @Test func `should gather every offer in one map at the top, not on the elements`() throws {
        let nested = AXNode(role: "AXButton", label: "Deep", frame: rect(0, 0, 40, 40))
        let group = AXNode(role: "AXGroup", frame: rect(0, 0, 402, 874), children: [nested])
        let root = try rendered(tree(group))

        #expect((root["affordances"] as? [String: Any])?["tap Deep"] != nil)
        let children = try #require(root["children"] as? [[String: Any]])
        #expect(children[0]["affordances"] == nil)
        #expect((children[0]["children"] as? [[String: Any]])?[0]["affordances"] == nil)
    }

    @Test func `should keep the map first in the output so nothing has to be filtered to find it`() {
        let json = tree(AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40))).json(affordances: Self.cli)

        #expect(json.hasPrefix(#"{"affordances":"#))
    }

    @Test func `should number controls that share a name`() throws {
        let first = AXNode(role: "AXButton", label: "Maps", frame: rect(0, 0, 40, 40))
        let second = AXNode(role: "AXButton", label: "Maps", frame: rect(0, 100, 40, 40))
        let map = try offers(first, second)

        #expect((map["tap Maps"] as? String)?.contains("--y 20") == true)
        #expect((map["tap Maps #2"] as? String)?.contains("--y 120") == true)
    }

    @Test func `should name an unlabelled control by its identifier, else its role`() throws {
        let identified = AXNode(role: "AXTextField", identifier: "MapsSearchTextField", frame: rect(0, 0, 40, 40))
        let bare = AXNode(role: "AXButton", frame: rect(0, 100, 40, 40))
        let map = try offers(identified, bare)

        #expect(map["tap MapsSearchTextField"] != nil)
        #expect(map["tap Button"] != nil)
    }

    @Test func `should keep a name on one line`() throws {
        let map = try offers(AXNode(role: "AXButton", label: "One\nTwo", frame: rect(0, 0, 40, 40)))

        #expect(map["tap One Two"] != nil)
    }

    @Test func `should keep a command's path readable so it can be copied as it stands`() {
        let style = AXAffordance.Style.commandLine(program: "/opt/baguette", udid: "X", deviceSet: nil)

        #expect(tree().json(affordances: style).contains("/opt/baguette press"))
    }

    @Test func `should offer home and a screenshot on the root`() throws {
        let root = try #require(try rendered(tree())["affordances"] as? [String: Any])

        #expect(root["home"] as? String == "baguette press --udid X --button home")
        #expect(root["screenshot"] as? String == "baguette screenshot --udid X --output /tmp/baguette-screen.jpg")
    }

    @Test func `should carry the program as it was run and a custom device set`() throws {
        let style = AXAffordance.Style.commandLine(program: "/opt/baguette", udid: "X", deviceSet: "/my set")
        let button = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40))

        #expect(try offers(button, style: style)["tap A"] as? String
            == #"/opt/baguette tap --udid X --device-set "/my set" --x 20 --y 20 --width 402 --height 874 --then-describe-ui"#)
    }

    @Test func `should answer a session in the wire form`() throws {
        let button = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40))
        let tap = try #require(try offers(button, style: .wire)["tap A"] as? [String: Any])

        #expect(tap["type"] as? String == "tap")
        #expect(tap["x"] as? Double == 20)
        #expect(tap["y"] as? Double == 20)
        #expect(tap["width"] as? Double == 402)
        #expect(tap["height"] as? Double == 874)
        #expect(tap["then_describe_ui"] as? Bool == true)
    }

    @Test func `should offer home but no screenshot in the wire form, which has no screenshot message`() throws {
        let root = try #require(try rendered(tree(), style: .wire)["affordances"] as? [String: Any])

        #expect((root["home"] as? [String: Any])?["button"] as? String == "home")
        #expect(root["screenshot"] == nil)
    }

    @Test func `should leave the plain JSON for scripts unchanged`() {
        let button = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40))

        #expect(!tree(button).json.contains("affordances"))
    }
}
