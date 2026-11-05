import Testing
import Foundation
import Mockable
@testable import Baguette

/// `describe_ui` on a gesture answers with what the gesture did and the
/// screen it left, so an agent gets one call per screen.
@Suite("ThenDescribe")
struct ThenDescribeTests {
    private static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
    private static let node = AXNode(role: "AXButton", label: "General", frame: frame)
    private static let immediate = AXSettle.Timing(quiet: 0, patience: 0, limit: 0, poll: 0)

    private func parsed(_ json: String?) throws -> [String: Any] {
        let text = try #require(json)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    private func accessibility(_ glances: [AXNode?], read: AXNode? = node) -> MockAccessibility {
        let ax = MockAccessibility()
        var remaining = glances
        given(ax).glance().willProduce { remaining.count > 1 ? remaining.removeFirst() : remaining.first ?? nil }
        given(ax).describeAll().willReturn(read)
        return ax
    }

    @Test func `should leave a gesture that did not ask to read for the gesture pipeline`() {
        let ax = accessibility([nil])
        for line in [#"{"type":"tap","x":1,"y":2}"#, "not json", #"{"type":"tap","describe_ui":false}"#] {
            #expect(ThenDescribe.dispatch(line: line, accessibility: ax, gesture: { _ in "unused" }, timing: Self.immediate) == nil)
        }
    }

    @Test func `should answer a gesture with its outcome and the new screen`() throws {
        let other = AXNode(role: "AXButton", label: "Other", frame: Self.frame)
        let ax = accessibility([Self.node, other])
        var sent: String?
        let line = #"{"type":"tap","x":1,"y":2,"width":3,"height":4,"then_describe_ui":true}"#

        let result = try parsed(ThenDescribe.dispatch(
            line: line, accessibility: ax, gesture: { sent = $0; return #"{"ok":true}"# }, timing: Self.immediate))

        #expect(sent == line)
        #expect(result["ok"] as? Bool == true)
        #expect(result["changed"] as? Bool == true)
        #expect((result["tree"] as? [String: Any])?["label"] as? String == "General")
    }

    @Test func `should say nothing changed when the gesture left the screen alone`() throws {
        let ax = accessibility([Self.node])

        let result = try parsed(ThenDescribe.dispatch(
            line: #"{"type":"tap","then_describe_ui":true}"#, accessibility: ax,
            gesture: { _ in #"{"ok":true}"# }, timing: Self.immediate))

        #expect(result["changed"] as? Bool == false)
    }

    @Test func `should pass on the gesture's own error without reading`() {
        let ax = accessibility([Self.node])
        let refused = #"{"ok":false,"error":"missing x"}"#

        let result = ThenDescribe.dispatch(
            line: #"{"type":"tap","then_describe_ui":true}"#, accessibility: ax, gesture: { _ in refused }, timing: Self.immediate)

        #expect(result == refused)
        verify(ax).describeAll().called(0)
    }

    @Test func `should still report the gesture when the read fails`() throws {
        let ax = MockAccessibility()
        given(ax).glance().willReturn(Self.node)
        given(ax).describeAll().willThrow(AXPTranslatorAccessibility.Failure.displayChanged)

        let result = try parsed(ThenDescribe.dispatch(
            line: #"{"type":"tap","then_describe_ui":true}"#, accessibility: ax,
            gesture: { _ in #"{"ok":true}"# }, timing: Self.immediate))

        #expect(result["ok"] as? Bool == true)
        #expect((result["error"] as? String)?.contains("observe again") == true)
    }

    @Test func `should offer the next commands to a command line caller`() throws {
        let tree = AXNode(
            role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)),
            children: [Self.node], screen: AXScreen(width: 402, height: 874, orientation: .portrait))
        let ax = MockAccessibility()
        given(ax).glance().willReturn(tree)
        given(ax).describeAll().willReturn(tree)

        let json = ThenDescribe.perform(
            action: "tap", accessibility: ax,
            affordances: .commandLine(program: "baguette", udid: "X", deviceSet: nil),
            timing: Self.immediate, act: { true })

        let root = try #require(try parsed(json)["tree"] as? [String: Any])
        #expect((root["affordances"] as? [String: Any])?["home"] as? String == "baguette press --udid X --button home")
    }

    @Test func `should name the action for a command line caller`() throws {
        let ax = accessibility([Self.node])

        let json = ThenDescribe.perform(action: "tap", accessibility: ax, timing: Self.immediate, act: { true })

        #expect(try parsed(json)["action"] as? String == "tap")
    }

    @Test func `should accept the flag on the tap command`() throws {
        let tap = try TapCommand.parse([
            "--udid", "X", "--x", "1", "--y", "2", "--width", "3", "--height", "4", "--then-describe-ui",
        ])

        #expect(tap.thenDescribeUI)
    }
}
