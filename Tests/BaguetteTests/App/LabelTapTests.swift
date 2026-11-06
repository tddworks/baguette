import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("LabelTap")
struct LabelTapTests {
    private static let frame = Rect(origin: Point(x: 28, y: 421), size: Size(width: 346, height: 58))
    private static let full = Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874))
    private static let search = AXNode(role: "AXButton", label: "Search flights", frame: frame)
    private static let screen = AXScreen(width: 402, height: 874, orientation: .portrait)
    private static let tree = AXNode(role: "AXApplication", frame: full, children: [search], screen: screen)
    private static let instant = LabelTap.Timing(find: 0, poll: 0, settle: AXSettle.Timing(quiet: 0, patience: 0, limit: 0, poll: 0))

    private func parsed(_ json: String?) throws -> [String: Any] {
        let text = try #require(json)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    private func ax(_ tree: AXNode? = LabelTapTests.tree, pressed: Bool = true) -> MockAccessibility {
        let ax = MockAccessibility()
        given(ax).glance().willReturn(tree)
        given(ax).describeAll().willReturn(tree)
        given(ax).press(.any).willReturn(pressed)
        return ax
    }

    private func dispatch(_ line: String, _ ax: MockAccessibility, gesture: (String) -> String = { _ in "unused" }) -> String? {
        LabelTap.dispatch(line: line, accessibility: ax, gesture: gesture, timing: Self.instant)
    }

    @Test func `should leave a tap at coordinates and other lines for their own pipelines`() {
        for line in [#"{"type":"tap","x":1,"y":2,"width":3,"height":4}"#, #"{"type":"swipe","label":"x"}"#, "not json"] {
            #expect(dispatch(line, ax()) == nil)
        }
    }

    @Test func `should press the named element without touching the screen`() throws {
        let accessibility = ax()
        var gestures = 0

        let result = try parsed(dispatch(#"{"type":"tap","label":"Search flights"}"#, accessibility, gesture: { _ in gestures += 1; return "" }))

        #expect(result["ok"] as? Bool == true)
        #expect(result["tapped"] as? String == "Search flights")
        #expect(gestures == 0)
        verify(accessibility).press(.value(Self.search)).called(1)
    }

    @Test func `should answer with the new screen when asked`() throws {
        let result = try parsed(dispatch(#"{"type":"tap","label":"Search flights","then_describe_ui":true}"#, ax()))

        #expect(result["tapped"] as? String == "Search flights")
        #expect(result["changed"] as? Bool == false)
        #expect((result["affordances"] as? [String: Any])?["tap Search flights"] != nil)
        #expect(result["tree"] == nil)
    }

    @Test func `should use a real touch at the element's centre when asked`() throws {
        let accessibility = ax()
        var sent: [String: Any] = [:]

        let result = try parsed(dispatch(
            #"{"type":"tap","label":"Search flights","touch":true,"duration":0.1}"#, accessibility,
            gesture: { sent = (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) ?? [:]; return #"{"ok":true}"# }))

        #expect(sent["x"] as? Double == 201)
        #expect(sent["y"] as? Double == 450)
        #expect(sent["width"] as? Double == 402)
        #expect(sent["height"] as? Double == 874)
        #expect(sent["duration"] as? Double == 0.1)
        #expect(sent["label"] == nil)
        #expect(sent["touch"] == nil)
        #expect(result["tapped"] as? String == "Search flights")
        verify(accessibility).press(.any).called(0)
    }

    @Test func `should refuse a real touch on an element off screen`() throws {
        let seat = AXNode(role: "AXButton", label: "Seat 20A", frame: Rect(origin: Point(x: 0, y: 1000), size: Size(width: 40, height: 40)))
        let tree = AXNode(role: "AXApplication", frame: Self.full, children: [seat], screen: Self.screen)

        let result = try parsed(dispatch(#"{"type":"tap","label":"Seat 20A","touch":true}"#, ax(tree)))

        #expect(result["ok"] as? Bool == false)
        #expect((result["error"] as? String)?.contains("off screen") == true)
    }

    @Test func `should press an element off screen without being asked to scroll`() throws {
        let seat = AXNode(role: "AXButton", label: "Seat 20A", frame: Rect(origin: Point(x: 0, y: 1000), size: Size(width: 40, height: 40)))
        let tree = AXNode(role: "AXApplication", frame: Self.full, children: [seat], screen: Self.screen)

        #expect(try parsed(dispatch(#"{"type":"tap","label":"Seat 20A"}"#, ax(tree)))["ok"] as? Bool == true)
    }

    @Test func `should touch the element when a press can't find it, because nothing has happened yet`() throws {
        var sent: [String: Any] = [:]

        let result = try parsed(dispatch(
            #"{"type":"tap","label":"Search flights"}"#, ax(pressed: false),
            gesture: { sent = (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) ?? [:]; return #"{"ok":true}"# }))

        #expect(result["ok"] as? Bool == true)
        #expect(result["tapped"] as? String == "Search flights")
        #expect(result["used"] as? String == "touch")
        #expect(sent["x"] as? Double == 201)
        #expect(sent["y"] as? Double == 450)
    }

    @Test func `should touch and answer with the new screen when a press can't find it`() throws {
        var gestures = 0

        let result = try parsed(dispatch(
            #"{"type":"tap","label":"Search flights","then_describe_ui":true}"#, ax(pressed: false),
            gesture: { _ in gestures += 1; return #"{"ok":true}"# }))

        #expect(gestures == 1)
        #expect(result["ok"] as? Bool == true)
        #expect(result["used"] as? String == "touch")
        #expect(result["affordances"] != nil)
    }

    @Test func `should not touch as well when a press worked`() throws {
        var gestures = 0

        _ = dispatch(#"{"type":"tap","label":"Search flights","then_describe_ui":true}"#, ax(), gesture: { _ in gestures += 1; return #"{"ok":true}"# })

        #expect(gestures == 0)
    }

    @Test func `should say so when an element off screen can't be pressed, because a finger can't reach it either`() throws {
        let seat = AXNode(role: "AXButton", label: "Seat 20A", frame: Rect(origin: Point(x: 0, y: 1000), size: Size(width: 40, height: 40)))
        let tree = AXNode(role: "AXApplication", frame: Self.full, children: [seat], screen: Self.screen)
        var gestures = 0

        let result = try parsed(dispatch(#"{"type":"tap","label":"Seat 20A"}"#, ax(tree, pressed: false), gesture: { _ in gestures += 1; return "" }))

        #expect(result["ok"] as? Bool == false)
        #expect((result["error"] as? String)?.contains("Seat 20A") == true)
        #expect(gestures == 0)
    }

    @Test func `should suggest a real touch when a press changes nothing`() throws {
        let result = try parsed(dispatch(#"{"type":"tap","label":"Search flights","then_describe_ui":true}"#, ax()))

        #expect((result["hint"] as? String)?.contains("--touch") == true)
    }

    @Test func `should name what is on screen when nothing matches`() throws {
        let accessibility = ax()
        let result = try parsed(dispatch(#"{"type":"tap","label":"Nope"}"#, accessibility))

        #expect(result["ok"] as? Bool == false)
        #expect((result["error"] as? String)?.contains("Nope") == true)
        #expect((result["affordances"] as? [String: Any])?["tap Search flights"] != nil)
        #expect(result["visible"] == nil)
        verify(accessibility).press(.any).called(0)
    }

    @Test func `should list the candidates rather than guess between them`() throws {
        let tree = AXNode(
            role: "AXApplication", frame: Self.full,
            children: [AXNode(role: "AXButton", label: "Seat 3F", frame: Self.frame), AXNode(role: "AXButton", label: "Seat 3E", frame: Self.frame)],
            screen: Self.screen)

        let result = try parsed(dispatch(#"{"type":"tap","label":"Seat 3"}"#, ax(tree)))

        #expect(result["ok"] as? Bool == false)
        #expect(result["matches"] as? [String] == ["Seat 3F", "Seat 3E"])
    }

    @Test func `should say why it won't tap a disabled element`() throws {
        let tree = AXNode(
            role: "AXApplication", frame: Self.full,
            children: [AXNode(role: "AXButton", label: "Pay", frame: Self.frame, enabled: false)], screen: Self.screen)

        let result = try parsed(dispatch(#"{"type":"tap","label":"Pay"}"#, ax(tree)))

        #expect((result["error"] as? String)?.contains("disabled") == true)
    }

    @Test func `should accept a label and a real touch on the tap command`() throws {
        let tap = try TapCommand.parse(["--udid", "X", "--label", "Pay", "--touch", "--then-describe-ui"])

        #expect(tap.label == "Pay")
        #expect(tap.touch)
    }

    @Test func `should refuse a tap command with neither a label nor a full position`() {
        #expect(throws: (any Error).self) { try TapCommand.parse(["--udid", "X"]) }
        #expect(throws: (any Error).self) { try TapCommand.parse(["--udid", "X", "--x", "1", "--y", "2"]) }
    }
}
