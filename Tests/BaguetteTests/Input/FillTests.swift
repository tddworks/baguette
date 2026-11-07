import Testing
import Foundation
import Mockable
@testable import Baguette

/// One field on a pretend screen. It answers the same reads a simulator does, and
/// keys change what it shows, so a test says what the app does and checks the outcome.
private final class Stage: @unchecked Sendable {
    var frame = Rect(origin: Point(x: 32, y: 183), size: Size(width: 338, height: 22))
    static let full = Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874))

    var role = "AXTextField"
    var subrole: String?
    var placeholder = "Email"
    var shows: String
    var focused = false
    var showsAfterTyping = ""
    var showsAfterPaste = ""
    var pressFocuses = true
    var touchFocuses = true
    /// The app moves on once keys land, as a form that submits on its last key does.
    var goneAfterTyping = false
    var gone = false
    var events: [String] = []

    init() { shows = placeholder }

    var tree: AXNode {
        let node = AXNode(role: role, subrole: subrole, value: shows, identifier: "email", frame: frame, focused: focused)
        return AXNode(role: "AXApplication", frame: Self.full, children: gone ? [] : [node],
                      screen: AXScreen(width: 402, height: 874, orientation: .portrait))
    }

    func accessibility() -> MockAccessibility {
        let ax = MockAccessibility()
        given(ax).glance().willProduce { self.tree }
        given(ax).describeAll().willProduce { self.tree }
        given(ax).press(.any).willProduce { _ in
            self.events.append("press")
            if self.pressFocuses { self.focused = true }
            return true
        }
        return ax
    }

    func input() -> MockInput {
        let cmdA = KeyboardKey.from(wireCode: "KeyA")!
        let cmdV = KeyboardKey.from(wireCode: "KeyV")!
        let backspace = KeyboardKey.from(wireCode: "Backspace")!
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willProduce { key, modifiers, _ in
            if key == cmdA, modifiers == [.command] {
                self.events.append("select all")
            } else if key == cmdV, modifiers == [.command] {
                self.events.append("paste")
                self.shows = self.showsAfterPaste
            } else if key == backspace {
                self.events.append("delete")
                self.shows = self.placeholder
            } else {
                if self.events.last != "type" { self.events.append("type") }
                self.shows = self.showsAfterTyping
                if self.goneAfterTyping { self.gone = true }
            }
            return true
        }
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any).willProduce { _, _, _, _ in
            self.events.append("touch")
            if self.touchFocuses { self.focused = true }
            return true
        }
        return input
    }

    func pasteboard() -> MockPasteboard {
        let pasteboard = MockPasteboard()
        given(pasteboard).setText(.any).willProduce { text in self.events.append("pasteboard \(text)") }
        return pasteboard
    }

    var inputTaken = false
    var askedAboutInput = 0

    func fill(_ text: String, into label: String = "email") async -> FillOutcome {
        await Fill(label: label, text: text).execute(
            accessibility: accessibility(), pasteboard: pasteboard(), input: input(), timing: .immediate,
            inputTaken: { self.askedAboutInput += 1; return self.inputTaken })
    }
}

extension Fill.Timing {
    fileprivate static let immediate = Fill.Timing(find: 0, focus: 0, readBack: 0, poll: 0)
}

@Suite("Fill")
struct FillTests {
    @Test func `should read the field and the text to put in it`() throws {
        let fill = try Fill.parse(["label": "email", "text": "gary"])
        #expect(fill == Fill(label: "email", text: "gary"))
    }

    @Test func `should reject a fill when no field or text is given`() {
        #expect(throws: GestureError.missingField("label")) { try Fill.parse(["text": "gary"]) }
        #expect(throws: GestureError.missingField("text")) { try Fill.parse(["label": "email"]) }
    }

    @Test func `should fill a text field and answer with what it shows`() async {
        let stage = Stage()
        stage.showsAfterTyping = "gary@example.com"

        let outcome = await stage.fill("gary@example.com")

        #expect(outcome == .filled(name: "email", shows: "gary@example.com"))
    }

    @Test func `should type nothing when the element isn't a text field`() async {
        let stage = Stage()
        stage.role = "AXSwitch"

        let outcome = await stage.fill("gary")

        guard case .notATextField(let name, _) = outcome else {
            Issue.record("expected notATextField, got \(outcome)")
            return
        }
        #expect(name == "email")
        #expect(stage.events.isEmpty)
    }

    @Test func `should say why when no element matches the name`() async {
        let stage = Stage()

        let outcome = await stage.fill("gary", into: "Nope")

        guard case .unreachable(let refusal) = outcome else {
            Issue.record("expected unreachable, got \(outcome)")
            return
        }
        #expect(refusal.message == "nothing matches Nope")
        #expect(stage.events.isEmpty)
    }

    @Test func `should touch a field on screen to focus it`() async {
        let stage = Stage()
        stage.showsAfterTyping = "gary"

        _ = await stage.fill("gary")

        #expect(stage.events.first == "touch")
    }

    @Test func `should press a field that's off screen to focus it`() async {
        let stage = Stage()
        stage.frame = Rect(origin: Point(x: 32, y: 2000), size: Size(width: 338, height: 22))
        stage.showsAfterTyping = "gary"

        let outcome = await stage.fill("gary")

        #expect(stage.events.first == "press")
        #expect(outcome == .filled(name: "email", shows: "gary"))
    }

    @Test func `should not touch a field that already has focus`() async {
        let stage = Stage()
        stage.focused = true
        stage.showsAfterTyping = "gary"

        _ = await stage.fill("gary")

        #expect(stage.events.first == "select all")
    }

    @Test func `should press a field when a touch doesn't focus it`() async {
        let stage = Stage()
        stage.touchFocuses = false
        stage.showsAfterTyping = "gary"

        let outcome = await stage.fill("gary")

        #expect(stage.events.prefix(2) == ["touch", "press"])
        #expect(outcome == .filled(name: "email", shows: "gary"))
    }

    @Test func `should type nothing when a field never takes focus`() async {
        let stage = Stage()
        stage.pressFocuses = false
        stage.touchFocuses = false

        let outcome = await stage.fill("gary")

        #expect(outcome == .neverFocused(name: "email"))
        #expect(stage.events == ["touch", "press"])
    }

    @Test func `should clear a field before entering text`() async {
        let stage = Stage()
        stage.showsAfterTyping = "gary"

        _ = await stage.fill("gary")

        #expect(stage.events == ["touch", "select all", "delete", "type"])
    }

    @Test func `should only clear when the text is empty`() async {
        let stage = Stage()
        stage.shows = "old"

        let outcome = await stage.fill("")

        #expect(outcome == .cleared(name: "email"))
        #expect(stage.events == ["touch", "select all", "delete"])
    }

    @Test func `should paste when the text can't be typed`() async {
        let stage = Stage()
        stage.showsAfterPaste = "café"

        let outcome = await stage.fill("café")

        #expect(stage.events == ["touch", "select all", "delete", "pasteboard café", "paste"])
        #expect(outcome == .filled(name: "email", shows: "café"))
    }

    @Test func `should paste once when a field shows something else`() async {
        let stage = Stage()
        stage.showsAfterTyping = "a—b"
        stage.showsAfterPaste = "a--b"

        let outcome = await stage.fill("a--b")

        #expect(stage.events == ["touch", "select all", "delete", "type", "select all", "delete", "pasteboard a--b", "paste"])
        #expect(outcome == .filled(name: "email", shows: "a--b"))
    }

    @Test func `should send no more keys when the field is gone after typing`() async {
        let stage = Stage()
        stage.goneAfterTyping = true

        let outcome = await stage.fill("gary")

        #expect(stage.events == ["touch", "select all", "delete", "type"])
        #expect(outcome == .failed("email is gone from the screen"))
    }

    @Test func `should count a field that only changes punctuation as filled`() async {
        let stage = Stage()
        stage.showsAfterTyping = "(555) 123"
        stage.showsAfterPaste = "(555) 123"

        let outcome = await stage.fill("555123")

        #expect(outcome == .filled(name: "email", shows: "(555) 123"))
    }

    @Test func `should report what a field shows when it still differs after a paste`() async {
        let stage = Stage()
        stage.showsAfterTyping = "gar"
        stage.showsAfterPaste = "gar"

        let outcome = await stage.fill("gary")

        #expect(outcome == .differs(name: "email", shows: "gar", wanted: #""gary""#))
    }

    @Test func `should not paste again when pasted text still differs`() async {
        let stage = Stage()
        stage.showsAfterPaste = "caf"

        let outcome = await stage.fill("café")

        #expect(stage.events.filter { $0 == "paste" }.count == 1)
        #expect(outcome == .differs(name: "email", shows: "caf", wanted: #""café""#))
    }

    @Test func `should keep a password off the pasteboard when it can be typed`() async {
        let stage = Stage()
        stage.subrole = "AXSecureTextField"
        stage.showsAfterTyping = "••"

        let outcome = await stage.fill("secret1")

        #expect(!stage.events.contains { $0.hasPrefix("pasteboard") })
        #expect(outcome == .differs(name: "email", shows: "••", wanted: "7 characters"))
    }

    @Test func `should fill a secure field by its number of characters`() async {
        let stage = Stage()
        stage.subrole = "AXSecureTextField"
        stage.showsAfterTyping = "•••••••"

        let outcome = await stage.fill("secret1")

        #expect(outcome == .filled(name: "email", shows: "•••••••"))
    }

    @Test func `should paste a password only when it can't be typed`() async {
        let stage = Stage()
        stage.subrole = "AXSecureTextField"
        stage.showsAfterPaste = "••••"

        let outcome = await stage.fill("café")

        #expect(stage.events.contains("pasteboard café"))
        #expect(outcome == .filled(name: "email", shows: "••••"))
    }

    @Test func `should report a failure when a key can't be sent`() async {
        let stage = Stage()
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(false)
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        stage.focused = true

        let outcome = await Fill(label: "email", text: "gary").execute(
            accessibility: stage.accessibility(), pasteboard: stage.pasteboard(), input: input, timing: .immediate)

        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    @Test func `should say Device Hub took the input when a fill didn't land and it's attached`() async {
        let stage = Stage()
        stage.inputTaken = true
        stage.showsAfterTyping = "Email"
        stage.showsAfterPaste = "Email"

        let outcome = await stage.fill("gary")

        #expect(outcome == .inputTaken(name: "email"))
    }

    @Test func `should say Device Hub took the input when a field never takes focus and it's attached`() async {
        let stage = Stage()
        stage.inputTaken = true
        stage.pressFocuses = false
        stage.touchFocuses = false

        let outcome = await stage.fill("gary")

        #expect(outcome == .inputTaken(name: "email"))
    }

    @Test func `should report what a field shows when a fill didn't land and Device Hub isn't attached`() async {
        let stage = Stage()
        stage.showsAfterTyping = "gar"
        stage.showsAfterPaste = "gar"

        let outcome = await stage.fill("gary")

        #expect(outcome == .differs(name: "email", shows: "gar", wanted: #""gary""#))
    }

    @Test func `should not ask about Device Hub when a fill lands`() async {
        let stage = Stage()
        stage.showsAfterTyping = "gary"

        _ = await stage.fill("gary")

        #expect(stage.askedAboutInput == 0)
    }

    @Test func `should say how to take the input back when Device Hub has it`() {
        let answer = FillOutcome.inputTaken(name: "email").answer()
        #expect(answer["ok"] as? Bool == false)
        #expect((answer["error"] as? String)?.contains("baguette heal") == true)
    }

    private func text(_ answer: [String: Any]) -> String { AXAffordance.json(answer) }

    @Test func `should answer a filled field with its name and what it shows`() {
        #expect(text(FillOutcome.filled(name: "email", shows: "gary").answer()) == #"{"filled":"email","ok":true,"value":"gary"}"#)
    }

    @Test func `should answer a cleared field as empty`() {
        #expect(text(FillOutcome.cleared(name: "email").answer()) == #"{"filled":"email","ok":true,"value":""}"#)
    }

    @Test func `should answer a field that differs with what it shows`() {
        let answer = FillOutcome.differs(name: "email", shows: "gar", wanted: #""gary""#).answer()
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["value"] as? String == "gar")
        #expect(answer["error"] as? String == #"email shows "gar", not "gary""#)
    }

    @Test func `should say nothing was typed when the element isn't a text field`() {
        let answer = FillOutcome.notATextField(name: "Remember me", screen: nil).answer()
        #expect(answer["error"] as? String == "Remember me isn't a text field, so nothing was typed")
    }

    @Test func `should say nothing was typed when a field never takes focus`() {
        let answer = FillOutcome.neverFocused(name: "email").answer()
        #expect(answer["error"] as? String == "email never took focus, so nothing was typed")
    }

    @Test func `should answer a name that reached nothing with what the screen offers`() {
        let tree = AXNode(
            role: "AXApplication", frame: Stage.full,
            children: [AXNode(role: "AXButton", label: "Pay", frame: Stage.full)])
        let answer = FillOutcome.unreachable(AXTarget.Refusal(message: "nothing matches x", screen: tree)).answer()

        #expect(answer["ok"] as? Bool == false)
        #expect(answer["error"] as? String == "nothing matches x")
        #expect(offeredNames(answer, "tap") == ["Pay"])
        #expect(answer["visible"] == nil)
    }

    @Test func `should answer an element that isn't a text field with what the screen offers`() async {
        let stage = Stage()
        stage.role = "AXSwitch"

        let answer = await stage.fill("gary").answer()

        #expect(offeredNames(answer, "tap") == ["email"])
    }

    @Test func `should offer the finished command to take the input back`() {
        let style = AXAffordance.Style.commandLine(program: "baguette", udid: "U", deviceSet: nil)
        #expect(FillOutcome.inputTaken(name: "email").answer(style)["try"] as? String == "baguette heal --udid U")
    }

    @Test func `should offer the way to take the input back when Device Hub has it`() {
        #expect(FillOutcome.inputTaken(name: "email").answer()["try"] as? String == "baguette heal --udid <udid>")
    }

    @Test func `should say ok only when the field shows the text`() {
        #expect(FillOutcome.filled(name: "e", shows: "x").isOK)
        #expect(FillOutcome.cleared(name: "e").isOK)
        #expect(!FillOutcome.differs(name: "e", shows: "x", wanted: "y").isOK)
        #expect(!FillOutcome.neverFocused(name: "e").isOK)
        #expect(!FillOutcome.notATextField(name: "e", screen: nil).isOK)
    }
}
