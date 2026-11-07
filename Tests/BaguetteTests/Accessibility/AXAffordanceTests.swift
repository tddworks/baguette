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

    private func commands(_ tree: AXNode, _ style: AXAffordance.Style = cli) -> [String: Any] {
        tree.agentSummary(style)["affordances"] as? [String: Any] ?? [:]
    }

    /// The names a verb is offered for, `nil` when it's offered for none.
    private func offered(_ tree: AXNode, _ verb: String) -> Set<String>? {
        ((commands(tree)[verb] as? [String: Any])?["names"] as? [String]).map(Set.init)
    }

    private func command(_ tree: AXNode, _ verb: String, _ style: AXAffordance.Style = cli) -> Any? {
        (commands(tree, style)[verb] as? [String: Any])?["command"]
    }

    private func tappable(_ tree: AXNode) -> Set<String>? { offered(tree, "tap") }

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

        #expect((summary["affordances"] as? [String: Any])?.isEmpty == true)
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

        #expect(offered(tree(identified, bare), "fill") == ["MapsSearchTextField"])
        #expect(tappable(tree(identified, bare)) == ["Button"])
    }

    @Test func `should keep a name on one line`() {
        #expect(tappable(tree(button("One\nTwo"))) == ["One Two"])
    }

    @Test func `should offer a slider as a drag from where it is now, because a press can't set a value`() {
        let slider = AXNode(role: "AXSlider", value: "50%", identifier: "DYNAMIC_TYPE_SLIDER", frame: rect(20, 760, 360, 40))
        let offers = commands(tree(slider, button("Done")))

        #expect(offers["swipe DYNAMIC_TYPE_SLIDER"] as? String
            == "baguette swipe --udid U --start-x 200 --start-y 780 --end-x <x> --end-y 780 --width 402 --height 874 --then-describe-ui")
        #expect(offered(tree(slider, button("Done")), "tap") == ["Done"])
        #expect(offers["adjust DYNAMIC_TYPE_SLIDER"] == nil)
    }

    // MARK: - the verb a control takes

    private func field(_ label: String, role: String = "AXTextField", focused: Bool = false) -> AXNode {
        AXNode(role: role, label: label, frame: rect(16, 132, 370, 44), focused: focused)
    }

    @Test func `should offer a text field to fill, not to tap`() {
        let screen = tree(field("Email"), button("Sign In"))

        #expect(offered(screen, "fill") == ["Email"])
        #expect(offered(screen, "tap") == ["Sign In"])
    }

    @Test func `should offer a secure field to fill`() {
        let secure = AXNode(role: "AXTextField", subrole: "AXSecureTextField", identifier: "password", frame: rect(16, 232, 370, 44))

        #expect(offered(tree(secure), "fill") == ["password"])
    }

    @Test func `should offer nothing to fill when the screen has no text field`() {
        #expect(offered(tree(button("Sign In")), "fill") == nil)
    }

    @Test func `should not offer to fill a disabled field`() {
        let disabled = AXNode(role: "AXTextField", label: "Email", frame: rect(16, 132, 370, 44), enabled: false)

        #expect(offered(tree(disabled), "fill") == nil)
    }

    @Test func `should offer a focused field to fill and to type`() {
        let screen = tree(field("City", focused: true))

        #expect(offered(screen, "fill") == ["City"])
        #expect(offered(screen, "type") == ["City"])
    }

    @Test func `should number a field and a button that share a name so each name reaches one`() {
        let name = field("Name")
        let action = button("Name")
        let screen = tree(name, action)

        #expect(offered(screen, "fill") == ["Name #1"])
        #expect(offered(screen, "tap") == ["Name #2"])
        #expect(AXTarget.find("Name #1", in: screen) == .found(name))
        #expect(AXTarget.find("Name #2", in: screen) == .found(action))
    }

    // MARK: - one command for each verb

    @Test func `should offer one command to fill any of the fields`() {
        #expect(command(tree(field("email"), field("password")), "fill") as? String
            == "baguette fill --udid U --label '<name>' --text <text>")
        #expect(offered(tree(field("email"), field("password")), "fill") == ["email", "password"])
    }

    @Test func `should offer one command to tap any of the controls`() {
        #expect(command(tree(button("Sign In"), button("Login")), "tap") as? String
            == "baguette tap --udid U --label '<name>' --then-describe-ui")
        #expect(offered(tree(button("Sign In"), button("Login")), "tap") == ["Sign In", "Login"])
    }

    @Test func `should offer one command to type into the focused field`() {
        #expect(command(tree(field("City", focused: true)), "type") as? String
            == "baguette type --udid U --text <text>")
    }

    @Test func `should list names in order, so a cut answer keeps what comes first`() {
        let names = (commands(tree(button("Seat 1A"), button("Continue")))["tap"] as? [String: Any])?["names"] as? [String]

        #expect(names == ["Continue", "Seat 1A"])
    }

    @Test func `should list seat 2 ahead of seat 10`() {
        let names = (commands(tree(button("Seat 10A"), button("Seat 2A")))["tap"] as? [String: Any])?["names"] as? [String]

        #expect(names == ["Seat 2A", "Seat 10A"])
    }

    @Test func `should put the command ahead of the names, so a cut answer keeps it`() {
        let text = AXAffordance.json(tree(button("Sign In")).agentSummary(Self.cli))

        #expect(text.contains(#""tap":{"command":"#))
    }

    @Test func `should offer the program as it was run and a custom device set`() {
        let style = AXAffordance.Style.commandLine(program: "/opt/baguette", udid: "U", deviceSet: "/my set")

        #expect(command(tree(button("A")), "tap", style) as? String
            == #"/opt/baguette tap --udid U --device-set "/my set" --label '<name>' --then-describe-ui"#)
    }

    @Test func `should offer a session the envelope, not a command`() {
        let screen = tree(field("email"), button("Sign In"))
        let tap = command(screen, "tap", .wire) as? [String: Any]
        let fill = command(screen, "fill", .wire) as? [String: Any]

        #expect(tap?["type"] as? String == "tap")
        #expect(tap?["label"] as? String == "<name>")
        #expect(tap?["then_describe_ui"] as? Bool == true)
        #expect(fill?["type"] as? String == "fill")
        #expect(fill?["label"] as? String == "<name>")
        #expect(fill?["text"] as? String == "<text>")
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

    @Test func `should have no separate section on how to act`() {
        #expect(tree(button("A")).agentSummary(Self.cli)["how"] == nil)
    }

    @Test func `should offer typing only when a text field is focused`() {
        let focused = AXNode(role: "AXTextField", label: "City", frame: rect(16, 132, 370, 44), focused: true)
        let idle = AXNode(role: "AXTextField", label: "Name", frame: rect(16, 232, 370, 44))

        #expect(offered(tree(focused), "type") == ["City"])
        #expect(offered(tree(idle), "type") == nil)
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

    @Test func `should not repeat the screen's size in an answer`() {
        #expect(tree(button("A")).agentSummary(Self.cli)["screen"] == nil)
    }

    @Test func `should leave the plain JSON for scripts unchanged`() {
        #expect(!tree(button("A")).json.contains("affordances"))
    }

    @Test func `should put what can be done first in describe-ui's JSON and keep the tree`() throws {
        let json = tree(button("A")).json(affordances: Self.cli)

        #expect(json.hasPrefix(#"{"affordances":"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["children"] as? [[String: Any]])?.count == 1)
        #expect(object["how"] == nil)
        #expect(object["role"] as? String == "AXApplication")
    }
}
