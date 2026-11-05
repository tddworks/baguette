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

    private func affordances(of child: AXNode, style: AXAffordance.Style = cli) throws -> [String: Any]? {
        let root = try rendered(tree(child), style: style)
        let children = try #require(root["children"] as? [[String: Any]])
        return children.first?["affordances"] as? [String: Any]
    }

    @Test func `should offer a ready tap on an enabled control on screen`() throws {
        let search = AXNode(role: "AXButton", label: "Search flights", frame: rect(28, 421, 346, 58))

        #expect(try affordances(of: search)?["tap"] as? String
            == "baguette tap --udid X --x 201 --y 450 --width 402 --height 874 --then-describe-ui")
    }

    @Test func `should offer no tap on a disabled element`() throws {
        let pay = AXNode(role: "AXButton", label: "Pay $1,240", frame: rect(16, 717, 370, 58), enabled: false)

        #expect(try affordances(of: pay) == nil)
    }

    @Test func `should offer no tap on an element off screen`() throws {
        for frame in [rect(48, 1000, 46, 40), rect(-200, 100, 46, 40)] {
            #expect(try affordances(of: AXNode(role: "AXButton", label: "Seat", frame: frame)) == nil)
        }
    }

    @Test func `should offer no tap on a hidden element or one with no size`() throws {
        #expect(try affordances(of: AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40), hidden: true)) == nil)
        #expect(try affordances(of: AXNode(role: "AXButton", label: "B", frame: rect(10, 10, 0, 0))) == nil)
    }

    @Test func `should offer no tap on text, images or containers because their role doesn't say they respond`() throws {
        for role in ["AXStaticText", "AXImage", "AXGroup", "AXHeading"] {
            #expect(try affordances(of: AXNode(role: role, label: "Text", frame: rect(0, 0, 40, 40))) == nil)
        }
    }

    @Test func `should tap near the left of a wide row whose label has several parts`() throws {
        let row = AXNode(role: "AXButton", label: "Orbit 3, 10h 10m, $1,240", frame: rect(16, 514, 370, 72))

        #expect(try affordances(of: row)?["tap"] as? String
            == "baguette tap --udid X --x 56 --y 550 --width 402 --height 874 --then-describe-ui")
    }

    @Test func `should tap the centre of a narrow element whose label has several parts`() throws {
        let chip = AXNode(role: "AXButton", label: "Paris, France", frame: rect(0, 0, 100, 40))

        #expect(try (affordances(of: chip)?["tap"] as? String)?.contains("--x 50 --y 20") == true)
    }

    @Test func `should tap the visible part of an element hanging off the screen`() throws {
        let row = AXNode(role: "AXButton", label: "Smart Invert", frame: rect(36, 860, 100, 28))

        #expect(try (affordances(of: row)?["tap"] as? String)?.contains("--x 86 --y 867") == true)
    }

    @Test func `should offer typing only on a focused text field`() throws {
        let focused = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44), focused: true)
        let idle = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44))

        #expect(try affordances(of: focused)?["type"] as? String == #"baguette type --udid X --text "<text>""#)
        #expect(try affordances(of: idle)?["type"] == nil)
        #expect(try affordances(of: idle)?["tap"] != nil)
    }

    @Test func `should offer home and a screenshot on the root`() throws {
        let root = try #require(try rendered(tree())["affordances"] as? [String: Any])

        #expect(root["home"] as? String == "baguette press --udid X --button home")
        #expect(root["screenshot"] as? String == "baguette screenshot --udid X --output /tmp/baguette-screen.jpg")
    }

    @Test func `should carry the program as it was run and a custom device set`() throws {
        let style = AXAffordance.Style.commandLine(program: "/opt/baguette", udid: "X", deviceSet: "/my set")
        let button = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40))

        #expect(try affordances(of: button, style: style)?["tap"] as? String
            == #"/opt/baguette tap --udid X --device-set "/my set" --x 20 --y 20 --width 402 --height 874 --then-describe-ui"#)
    }

    @Test func `should answer a session in the wire form`() throws {
        let button = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40))
        let tap = try #require(try affordances(of: button, style: .wire)?["tap"] as? [String: Any])

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
