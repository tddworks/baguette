import Testing
import Foundation
import Mockable
@testable import Baguette

/// A long-lived `baguette input` session answers `describe_ui` itself,
/// so one process can both look and act without paying startup per call.
@Suite("DescribeUIDispatch")
struct DescribeUIDispatchTests {
    private static let node = AXNode(
        role: "AXButton", label: "General",
        frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 40, height: 40)))

    private func result(_ ack: String?) throws -> [String: Any] {
        let data = Data(try #require(ack).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func `should leave a line that is not describe_ui for the gesture pipeline`() {
        let ax = MockAccessibility()
        for line in [#"{"type":"tap","x":1,"y":2}"#, "not json", #"{"no_type":true}"#] {
            #expect(DescribeUIDispatch.dispatch(line: line, accessibility: ax) == nil)
        }
    }

    @Test func `should answer with the whole tree`() throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(Self.node)

        let ack = try result(DescribeUIDispatch.dispatch(line: #"{"type":"describe_ui"}"#, accessibility: ax))

        #expect(ack["type"] as? String == "describe_ui_result")
        #expect(ack["ok"] as? Bool == true)
        #expect((ack["tree"] as? [String: Any])?["label"] as? String == "General")
    }

    @Test func `should describe the element at a point`() throws {
        let ax = MockAccessibility()
        given(ax).describeAt(point: .any).willReturn(Self.node)

        let ack = try result(
            DescribeUIDispatch.dispatch(line: #"{"type":"describe_ui","x":5,"y":6}"#, accessibility: ax))

        #expect(ack["ok"] as? Bool == true)
        verify(ax).describeAt(point: .any).called(1)
    }

    @Test func `should say there is no data when no app is frontmost`() throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(nil)

        let ack = try result(DescribeUIDispatch.dispatch(line: #"{"type":"describe_ui"}"#, accessibility: ax))

        #expect(ack["ok"] as? Bool == false)
        #expect(ack["error"] as? String == "no accessibility data")
    }

    @Test func `should report the failure when the read fails`() throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willThrow(AXPTranslatorAccessibility.Failure.displayChanged)

        let ack = try result(DescribeUIDispatch.dispatch(line: #"{"type":"describe_ui"}"#, accessibility: ax))

        #expect(ack["ok"] as? Bool == false)
        #expect((ack["error"] as? String)?.contains("observe again") == true)
    }
}
