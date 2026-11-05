import Testing
import Foundation
@testable import Baguette

/// An affordance is what an agent can do on this screen right now. Baguette
/// presses a control through accessibility, by name, so where it is doesn't matter:
/// only whether it's enabled.
@Suite("AXNode agent summary")
struct AXAffordanceTests {
    private static let cli = AXAffordance.Style.commandLine(program: "baguette", udid: "U", deviceSet: nil)

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    private func tree(_ children: AXNode...) -> AXNode {
        AXNode(
            role: "AXApplication", label: "Skylark", frame: rect(0, 0, 402, 874), children: children,
            screen: AXScreen(width: 402, height: 874, orientation: .portrait))
    }

    private func button(_ label: String, _ frame: Rect = Rect(origin: Point(x: 0, y: 100), size: Size(width: 40, height: 40)), enabled: Bool = true) -> AXNode {
        AXNode(role: "AXButton", label: label, frame: frame, enabled: enabled)
    }

    private func tappable(_ tree: AXNode) -> [String]? {
        (tree.agentSummary(Self.cli)["affordances"] as? [String: Any])?["tap"] as? [String]
    }

    @Test func `should list every enabled control as tappable by name`() {
        #expect(tappable(tree(button("Search flights"))) == ["Search flights"])
    }

    @Test func `should list a control wherever it is, because a press doesn't need to reach it`() {
        let below = button("Seat 20A", rect(48, 1000, 46, 40))
        let underBar = button("Seat 15A", rect(48, 796, 46, 40))
        let bar = AXNode(role: "AXGroup", label: "Tab Bar", frame: rect(0, 791, 402, 83))

        #expect(tappable(tree(below, underBar, bar)) == ["Seat 20A", "Seat 15A"])
    }

    @Test func `should list a disabled control apart, not as something to do`() {
        let summary = tree(button("Pay $1,240", enabled: false)).agentSummary(Self.cli)

        #expect((summary["affordances"] as? [String: Any])?["tap"] == nil)
        #expect(summary["disabled"] as? [String] == ["Pay $1,240"])
    }

    @Test func `should leave out what is hidden or has no size`() {
        let hidden = AXNode(role: "AXButton", label: "A", frame: rect(0, 0, 40, 40), hidden: true)

        #expect(tappable(tree(hidden, button("B", rect(10, 10, 0, 0)))) == nil)
    }

    @Test func `should number controls that share a name`() {
        #expect(tappable(tree(button("Maps"), button("Maps", rect(0, 200, 40, 40)))) == ["Maps #1", "Maps #2"])
    }

    @Test func `should name an unlabelled control by its identifier, else its role`() {
        let identified = AXNode(role: "AXTextField", identifier: "MapsSearchTextField", frame: rect(0, 100, 40, 40))
        let bare = AXNode(role: "AXButton", frame: rect(0, 200, 40, 40))

        #expect(tappable(tree(identified, bare)) == ["MapsSearchTextField", "Button"])
    }

    @Test func `should keep a name on one line`() {
        #expect(tappable(tree(button("One\nTwo"))) == ["One Two"])
    }

    @Test func `should offer typing only when a text field is focused`() {
        let focused = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44), focused: true)
        let idle = AXNode(role: "AXTextField", label: "Name", frame: rect(16, 232, 370, 44))

        #expect((tree(focused).agentSummary(Self.cli)["affordances"] as? [String: Any])?["type"] as? [String] == ["City"])
        #expect((tree(idle).agentSummary(Self.cli)["affordances"] as? [String: Any])?["type"] == nil)
    }

    @Test func `should say what the screen says, without the status bar or what's off screen`() {
        let summary = tree(
            AXNode(role: "AXStaticText", label: "12:09 PM", frame: rect(52, 14, 45, 22)),
            AXNode(role: "AXHeading", label: "SFO to HND", frame: rect(153, 74, 95, 21)),
            AXNode(role: "AXStaticText", label: "See all", frame: rect(336, 505, 50, 20)),
            AXNode(role: "AXImage", label: "Swap", frame: rect(324, 260, 39, 39)),
            AXNode(role: "AXStaticText", label: "Below", frame: rect(0, 900, 40, 20)),
            button("Not text")
        ).agentSummary(Self.cli)

        #expect(summary["text"] as? [String] == ["SFO to HND", "See all", "Swap"])
    }

    @Test func `should give the value of a control that has one`() {
        let toggle = AXNode(role: "AXCheckBox", subrole: "AXSwitch", label: "Bold Text", value: "0", frame: rect(36, 146, 330, 28))

        #expect(tree(toggle).agentSummary(Self.cli)["values"] as? [String: String] == ["Bold Text": "0"])
    }

    @Test func `should not repeat what never changes in the answer to a tap`() throws {
        let summary = tree(button("A")).agentSummary(Self.cli)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: summary), as: UTF8.self)

        #expect(!text.contains("--udid"))
        #expect(summary["how"] == nil)
        #expect(summary["screen"] == nil)
    }

    @Test func `should say how to act once, for a caller that hasn't yet`() {
        let how = tree(button("A")).agentSummary(Self.cli, withHow: true)["how"] as? [String: Any]

        #expect(how?["tap"] as? String == "baguette tap --udid U --label '<name>' --then-describe-ui")
        #expect(how?["swipe"] as? String
            == "baguette swipe --udid U --start-x <x> --start-y <y> --end-x <x> --end-y <y> --width 402 --height 874 --then-describe-ui")
    }

    @Test func `should say how with the program as it was run and a custom device set`() {
        let style = AXAffordance.Style.commandLine(program: "/opt/baguette", udid: "U", deviceSet: "/my set")
        let how = tree().agentSummary(style, withHow: true)["how"] as? [String: Any]

        #expect(how?["tap"] as? String == #"/opt/baguette tap --udid U --device-set "/my set" --label '<name>' --then-describe-ui"#)
    }

    @Test func `should say how in the wire form to a session`() {
        let how = tree().agentSummary(.wire, withHow: true)["how"] as? [String: Any]
        let tap = how?["tap"] as? [String: Any]

        #expect(tap?["type"] as? String == "tap")
        #expect(tap?["label"] as? String == "<name>")
        #expect(tap?["then_describe_ui"] as? Bool == true)
    }

    @Test func `should stay small on a screen with many controls`() throws {
        let seats = (1...20).flatMap { row in
            ["A", "B", "C", "D", "E", "F"].enumerated().map { column, letter in
                button("Seat \(row)\(letter)", rect(48 + Double(column) * 52, 90 + Double(row) * 46, 46, 40))
            }
        }
        let big = AXNode(
            role: "AXApplication", frame: rect(0, 0, 402, 874), children: seats,
            screen: AXScreen(width: 402, height: 874, orientation: .portrait))

        #expect(try JSONSerialization.data(withJSONObject: big.agentSummary(Self.cli)).count < 2500)
    }

    @Test func `should leave the plain JSON for scripts unchanged`() {
        #expect(!tree(button("A")).json.contains("affordances"))
    }

    @Test func `should put what can be done first in describe-ui's JSON and keep the tree`() throws {
        let json = tree(button("A")).json(affordances: Self.cli)

        #expect(json.hasPrefix(#"{"affordances":"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["children"] as? [[String: Any]])?.count == 1)
        #expect(object["how"] != nil)
        #expect(object["role"] as? String == "AXApplication")
    }
}
