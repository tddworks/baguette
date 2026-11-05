import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("LabelTap")
struct LabelTapTests {
    private static let frame = Rect(origin: Point(x: 28, y: 421), size: Size(width: 346, height: 58))
    private static let search = AXNode(role: "AXButton", label: "Search flights", frame: frame)
    private static let screen = AXScreen(width: 402, height: 874, orientation: .portrait)
    private static let tree = AXNode(
        role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)),
        children: [search], screen: screen)
    private static let instant = LabelTap.Timing(find: 0, poll: 0, settle: AXSettle.Timing(quiet: 0, patience: 0, limit: 0, poll: 0))

    private func parsed(_ json: String?) throws -> [String: Any] {
        let text = try #require(json)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    private func ax(_ tree: AXNode? = LabelTapTests.tree) -> MockAccessibility {
        let ax = MockAccessibility()
        given(ax).glance().willReturn(tree)
        given(ax).describeAll().willReturn(tree)
        return ax
    }

    @Test func `should leave a tap at coordinates and other lines for their own pipelines`() {
        for line in [#"{"type":"tap","x":1,"y":2,"width":3,"height":4}"#, #"{"type":"swipe","label":"x"}"#, "not json"] {
            #expect(LabelTap.dispatch(line: line, accessibility: ax(), gesture: { _ in "unused" }, timing: Self.instant) == nil)
        }
    }

    @Test func `should tap the named element at coordinates the gesture pipeline understands`() throws {
        var sent: [String: Any] = [:]

        let result = try parsed(LabelTap.dispatch(
            line: #"{"type":"tap","label":"Search flights","duration":0.1}"#, accessibility: ax(),
            gesture: { sent = (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) ?? [:]; return #"{"ok":true}"# },
            timing: Self.instant))

        #expect(sent["type"] as? String == "tap")
        #expect(sent["x"] as? Double == 201)
        #expect(sent["y"] as? Double == 450)
        #expect(sent["width"] as? Double == 402)
        #expect(sent["height"] as? Double == 874)
        #expect(sent["duration"] as? Double == 0.1)
        #expect(sent["label"] == nil)
        #expect(result["ok"] as? Bool == true)
        #expect(result["tapped"] as? String == "Search flights")
    }

    @Test func `should answer with the new screen when asked`() throws {
        let result = try parsed(LabelTap.dispatch(
            line: #"{"type":"tap","label":"Search flights","then_describe_ui":true}"#, accessibility: ax(),
            gesture: { _ in #"{"ok":true}"# }, timing: Self.instant))

        #expect(result["tapped"] as? String == "Search flights")
        #expect(result["changed"] as? Bool == false)
        #expect(result["affordances"] != nil)
    }

    @Test func `should name what is on screen when nothing matches`() throws {
        var gestures = 0
        let result = try parsed(LabelTap.dispatch(
            line: #"{"type":"tap","label":"Nope"}"#, accessibility: ax(),
            gesture: { _ in gestures += 1; return "" }, timing: Self.instant))

        #expect(result["ok"] as? Bool == false)
        #expect((result["error"] as? String)?.contains("Nope") == true)
        #expect(result["visible"] as? [String] == ["Search flights"])
        #expect(gestures == 0)
    }

    @Test func `should list the candidates rather than guess between them`() throws {
        let tree = AXNode(
            role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)),
            children: [
                AXNode(role: "AXButton", label: "Seat 3F", frame: Self.frame),
                AXNode(role: "AXButton", label: "Seat 3E", frame: Self.frame),
            ], screen: Self.screen)

        let result = try parsed(LabelTap.dispatch(
            line: #"{"type":"tap","label":"Seat 3"}"#, accessibility: ax(tree),
            gesture: { _ in "" }, timing: Self.instant))

        #expect(result["ok"] as? Bool == false)
        #expect(result["matches"] as? [String] == ["Seat 3F", "Seat 3E"])
    }

    @Test func `should say why it won't tap a disabled element`() throws {
        let tree = AXNode(
            role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)),
            children: [AXNode(role: "AXButton", label: "Pay", frame: Self.frame, enabled: false)], screen: Self.screen)

        let result = try parsed(LabelTap.dispatch(
            line: #"{"type":"tap","label":"Pay"}"#, accessibility: ax(tree),
            gesture: { _ in "" }, timing: Self.instant))

        #expect((result["error"] as? String)?.contains("disabled") == true)
    }

    @Test func `should say to scroll for an element off screen`() throws {
        let tree = AXNode(
            role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)),
            children: [AXNode(role: "AXButton", label: "Seat 20A", frame: Rect(origin: Point(x: 0, y: 1000), size: Size(width: 40, height: 40)))],
            screen: Self.screen)

        let result = try parsed(LabelTap.dispatch(
            line: #"{"type":"tap","label":"Seat 20A"}"#, accessibility: ax(tree),
            gesture: { _ in "" }, timing: Self.instant))

        #expect((result["error"] as? String)?.contains("scroll") == true)
    }

    @Test func `should accept a label on the tap command without coordinates`() throws {
        let tap = try TapCommand.parse(["--udid", "X", "--label", "Pay", "--then-describe-ui"])

        #expect(tap.label == "Pay")
    }

    @Test func `should refuse a tap command with neither a label nor a full position`() {
        #expect(throws: (any Error).self) { try TapCommand.parse(["--udid", "X"]) }
        #expect(throws: (any Error).self) { try TapCommand.parse(["--udid", "X", "--x", "1", "--y", "2"]) }
    }
}
