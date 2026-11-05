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
        #expect(result["affordances"] != nil)
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

        #expect((try parsed(json)["affordances"] as? [String: Any])?["home"] as? String == "baguette press --udid X --button home")
    }

    private static let cli = AXAffordance.Style.commandLine(program: "baguette", udid: "X", deviceSet: nil)
    private static let row = AXNode(
        role: "AXButton", label: "Orbit 3, 10h 10m, $1,240",
        frame: Rect(origin: Point(x: 16, y: 514), size: Size(width: 370, height: 72)))
    private static let screenTree = AXNode(
        role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)),
        children: [row], screen: AXScreen(width: 402, height: 874, orientation: .portrait))

    private func axShowing(_ tree: AXNode) -> MockAccessibility {
        let ax = MockAccessibility()
        given(ax).glance().willReturn(tree)
        given(ax).describeAll().willReturn(tree)
        return ax
    }

    @Test func `should offer the element's own command when a tap on it changes nothing`() throws {
        let result = try parsed(ThenDescribe.perform(
            action: "tap", at: Point(x: 200, y: 550), accessibility: axShowing(Self.screenTree),
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect(result["changed"] as? Bool == false)
        #expect(result["try"] as? String
            == "baguette tap --udid X --x 56 --y 550 --width 402 --height 874 --then-describe-ui")
        #expect((result["hint"] as? String)?.contains("Orbit 3") == true)
    }

    @Test func `should not repeat the same point when that is what was already tapped`() throws {
        let result = try parsed(ThenDescribe.perform(
            action: "tap", at: Point(x: 56, y: 550), accessibility: axShowing(Self.screenTree),
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect(result["changed"] as? Bool == false)
        #expect(result["try"] == nil)
        #expect((result["hint"] as? String)?.contains("may not respond") == true)
    }

    @Test func `should say nothing was there when a tap on empty space changes nothing`() throws {
        let result = try parsed(ThenDescribe.perform(
            action: "tap", at: Point(x: 200, y: 100), accessibility: axShowing(Self.screenTree),
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect(result["try"] == nil)
        #expect((result["hint"] as? String)?.contains("no control") == true)
    }

    @Test func `should give no hint when the tap changed the screen`() throws {
        let other = AXNode(role: "AXApplication", label: "Other", frame: Self.screenTree.frame, screen: Self.screenTree.screen)
        let ax = MockAccessibility()
        var glances = [Self.screenTree, other]
        given(ax).glance().willProduce { glances.count > 1 ? glances.removeFirst() : glances[0] }
        given(ax).describeAll().willReturn(other)

        let result = try parsed(ThenDescribe.perform(
            action: "tap", at: Point(x: 200, y: 550), accessibility: ax,
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect(result["changed"] as? Bool == true)
        #expect(result["hint"] == nil)
        #expect(result["try"] == nil)
    }

    @Test func `should give a session the same hint for the point in its envelope`() throws {
        let result = try parsed(ThenDescribe.dispatch(
            line: #"{"type":"tap","x":200,"y":550,"width":402,"height":874,"then_describe_ui":true}"#,
            accessibility: axShowing(Self.screenTree), gesture: { _ in #"{"ok":true}"# }, timing: Self.immediate))

        #expect((result["try"] as? [String: Any])?["x"] as? Double == 56)
    }

    @Test func `should answer with what can be done and what the screen says, not the whole tree`() throws {
        let result = try parsed(ThenDescribe.perform(
            action: "tap", at: Point(x: 56, y: 550), accessibility: axShowing(Self.screenTree),
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect((result["affordances"] as? [String: Any])?["home"] != nil)
        #expect(result["screen"] != nil)
        #expect(result["tree"] == nil)
    }

    @Test func `should say a swipe that moved nothing may have reached the end`() throws {
        let result = try parsed(ThenDescribe.perform(
            action: "swipe", unchangedHint: ThenDescribe.swipeUnchanged, accessibility: axShowing(Self.screenTree),
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect(result["action"] as? String == "swipe")
        #expect(result["changed"] as? Bool == false)
        #expect((result["hint"] as? String)?.contains("end") == true)
    }

    @Test func `should give a session the same hint for a swipe`() throws {
        let line = #"{"type":"swipe","startX":201,"startY":700,"endX":201,"endY":200,"width":402,"height":874,"then_describe_ui":true}"#

        let result = try parsed(ThenDescribe.dispatch(
            line: line, accessibility: axShowing(Self.screenTree),
            gesture: { _ in #"{"ok":true}"# }, timing: Self.immediate))

        #expect((result["hint"] as? String)?.contains("end") == true)
    }

    @Test func `should give no hint when a swipe moved the screen`() throws {
        let scrolled = AXNode(role: "AXApplication", label: "Scrolled", frame: Self.screenTree.frame, screen: Self.screenTree.screen)
        let ax = MockAccessibility()
        var glances = [Self.screenTree, scrolled]
        given(ax).glance().willProduce { glances.count > 1 ? glances.removeFirst() : glances[0] }
        given(ax).describeAll().willReturn(scrolled)

        let result = try parsed(ThenDescribe.perform(
            action: "swipe", unchangedHint: ThenDescribe.swipeUnchanged, accessibility: ax,
            affordances: Self.cli, timing: Self.immediate, act: { true }))

        #expect(result["changed"] as? Bool == true)
        #expect(result["hint"] == nil)
    }

    @Test func `should accept the flag on the swipe command`() throws {
        let swipe = try SwipeCommand.parse([
            "--udid", "X", "--start-x", "201", "--start-y", "700", "--end-x", "201", "--end-y", "200",
            "--width", "402", "--height", "874", "--then-describe-ui",
        ])

        #expect(swipe.thenDescribeUI)
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
