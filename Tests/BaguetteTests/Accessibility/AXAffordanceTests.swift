import Testing
import Foundation
@testable import Baguette

/// What an agent needs after each step, small enough to read without filtering:
/// what it can do, and what the screen says. Agents filter a long answer, and
/// lose whatever the filter drops.
@Suite("AXNode agent summary")
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

    private func button(_ label: String, _ frame: Rect, enabled: Bool = true) -> AXNode {
        AXNode(role: "AXButton", label: label, frame: frame, enabled: enabled)
    }

    private func offers(_ tree: AXNode, style: AXAffordance.Style = cli) -> [String: Any] {
        tree.agentSummary(style)["affordances"] as? [String: Any] ?? [:]
    }

    @Test func `should offer one command to tap by name and the names it takes`() {
        let map = offers(tree(button("Search flights", rect(28, 421, 346, 58))))

        #expect(map["tap"] as? String == #"baguette tap --udid X --label "<name>" --then-describe-ui"#)
        #expect(map["tap_names"] as? [String] == ["Search flights"])
    }

    @Test func `should offer home and a screenshot`() {
        let map = offers(tree())

        #expect(map["home"] as? String == "baguette press --udid X --button home")
        #expect(map["screenshot"] as? String == "baguette screenshot --udid X --output /tmp/baguette-screen.jpg")
    }

    @Test func `should list a disabled control apart, so it isn't a mystery why it can't be tapped`() {
        let map = offers(tree(button("Pay $1,240", rect(16, 717, 370, 58), enabled: false)))

        #expect(map["tap_names"] == nil)
        #expect(map["disabled"] as? [String] == ["Pay $1,240"])
    }

    @Test func `should list a control off screen apart`() {
        let map = offers(tree(button("Seat 20A", rect(48, 1000, 46, 40)), button("Left", rect(-200, 100, 46, 40))))

        #expect(map["tap_names"] == nil)
        #expect(map["off_screen"] as? [String] == ["Seat 20A", "Left"])
    }

    @Test func `should list a control under a floating bar apart`() {
        let tabBar = AXNode(role: "AXGroup", label: "Tab Bar", frame: rect(0, 791, 402, 83))
        let map = offers(tree(button("Seat 15A", rect(48, 796, 46, 40)), button("Seat 3F", rect(308, 224, 46, 40)), tabBar))

        #expect(map["covered"] as? [String] == ["Seat 15A"])
        #expect(map["tap_names"] as? [String] == ["Seat 3F"])
    }

    @Test func `should not call a tab covered by its own tab bar when the tree lists the bar after it`() {
        let tab = AXNode(role: "AXRadioButton", subrole: "AXTabButton", label: "Trips", frame: rect(110, 795, 98, 54))
        let tabBar = AXNode(role: "AXGroup", label: "Tab Bar", frame: rect(0, 791, 402, 83))
        let map = offers(tree(tab, tabBar))

        #expect(map["covered"] == nil)
        #expect(map["tap_names"] as? [String] == ["Trips"])
    }

    @Test func `should list a control under a later button apart`() {
        let map = offers(tree(button("Seat 14A", rect(48, 750, 46, 40)), button("Continue with 3F", rect(16, 737, 370, 54))))

        #expect(map["covered"] as? [String] == ["Seat 14A"])
        #expect(map["tap_names"] as? [String] == ["Continue with 3F"])
    }

    @Test func `should leave out hidden elements and ones with no size`() {
        let hidden = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40), hidden: true)
        let map = offers(tree(hidden, button("B", rect(10, 10, 0, 0))))

        #expect(map["tap_names"] == nil)
        #expect(map["off_screen"] == nil)
    }

    @Test func `should give each of several controls that share a name its own coordinates`() {
        let map = offers(tree(button("Maps", rect(0, 100, 40, 40)), button("Maps", rect(0, 200, 40, 40))))

        #expect(map["tap_names"] == nil)
        #expect((map["tap Maps"] as? String)?.contains("--x 20 --y 120") == true)
        #expect((map["tap Maps #2"] as? String)?.contains("--x 20 --y 220") == true)
    }

    @Test func `should name an unlabelled control by its identifier`() {
        let map = offers(tree(AXNode(role: "AXTextField", identifier: "MapsSearchTextField", frame: rect(0, 100, 40, 40))))

        #expect(map["tap_names"] as? [String] == ["MapsSearchTextField"])
    }

    @Test func `should give a control with no name at all its coordinates`() {
        let map = offers(tree(AXNode(role: "AXButton", frame: rect(0, 100, 40, 40))))

        #expect(map["tap_names"] == nil)
        #expect((map["tap Button"] as? String)?.contains("--x 20 --y 120") == true)
    }

    @Test func `should offer typing only on a focused text field`() {
        let focused = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44), focused: true)
        let idle = AXNode(role: "AXTextField", label: "Name", frame: rect(16, 232, 370, 44))
        let map = offers(tree(focused, idle))

        #expect(map["type City"] as? String == #"baguette type --udid X --text "<text>""#)
        #expect(map["type Name"] == nil)
    }

    @Test func `should carry the program as it was run and a custom device set`() {
        let style = AXAffordance.Style.commandLine(program: "/opt/baguette", udid: "X", deviceSet: "/my set")

        #expect(offers(tree(button("A", rect(0, 100, 40, 40))), style: style)["tap"] as? String
            == #"/opt/baguette tap --udid X --device-set "/my set" --label "<name>" --then-describe-ui"#)
    }

    @Test func `should answer a session in the wire form`() {
        let map = offers(tree(button("A", rect(0, 100, 40, 40))), style: .wire)
        let tap = map["tap"] as? [String: Any]

        #expect(tap?["type"] as? String == "tap")
        #expect(tap?["label"] as? String == "<name>")
        #expect(tap?["then_describe_ui"] as? Bool == true)
        #expect((map["home"] as? [String: Any])?["button"] as? String == "home")
        #expect(map["screenshot"] == nil)
    }

    @Test func `should say what the screen says, without the status bar`() {
        let summary = tree(
            AXNode(role: "AXStaticText", label: "12:09 PM", frame: rect(52, 14, 45, 22)),
            AXNode(role: "AXHeading", label: "SFO to HND", frame: rect(153, 74, 95, 21)),
            AXNode(role: "AXStaticText", label: "See all", frame: rect(336, 505, 50, 20)),
            AXNode(role: "AXImage", label: "Swap", frame: rect(324, 260, 39, 39)),
            AXNode(role: "AXStaticText", label: "Below", frame: rect(0, 900, 40, 20)),
            button("Not text", rect(0, 100, 40, 40))
        ).agentSummary(Self.cli)

        #expect(summary["text"] as? [String] == ["SFO to HND", "See all", "Swap"])
    }

    @Test func `should give the value of a control that has one`() {
        let toggle = AXNode(role: "AXCheckBox", subrole: "AXSwitch", label: "Bold Text", value: "0", frame: rect(36, 146, 330, 28))

        #expect(tree(toggle).agentSummary(Self.cli)["values"] as? [String: String] == ["Bold Text": "0"])
    }

    @Test func `should give the screen size for a tap at coordinates`() {
        let screen = tree().agentSummary(Self.cli)["screen"] as? [String: Double]

        #expect(screen == ["width": 402, "height": 874])
    }

    @Test func `should stay far smaller than the tree on a screen with many controls`() throws {
        let seats = (1...20).flatMap { row in
            ["A", "B", "C", "D", "E", "F"].enumerated().map { column, letter in
                button("Seat \(row)\(letter)", rect(48 + Double(column) * 52, 90 + Double(row) * 46, 46, 40))
            }
        }
        let big = AXNode(
            role: "AXApplication", frame: rect(0, 0, 402, 874), children: seats,
            screen: AXScreen(width: 402, height: 874, orientation: .portrait))
        let summary = try JSONSerialization.data(withJSONObject: big.agentSummary(Self.cli))

        #expect(summary.count < 4000)
    }

    @Test func `should leave the plain JSON for scripts unchanged`() {
        #expect(!tree(button("A", rect(0, 0, 40, 40))).json.contains("affordances"))
    }

    @Test func `should add the map to describe-ui's JSON without changing the tree`() throws {
        let json = tree(button("A", rect(0, 100, 40, 40))).json(affordances: Self.cli)

        #expect(json.hasPrefix(#"{"affordances":"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["children"] as? [[String: Any]])?.count == 1)
    }
}
