import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("DescribeUI")
struct DescribeUITests {
    private static let full = Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874))
    private static let button = AXNode(
        role: "AXButton", label: "Sign In",
        frame: Rect(origin: Point(x: 16, y: 324), size: Size(width: 370, height: 52)))
    private static let status = AXNode(
        role: "AXStaticText", label: "Not signed in",
        frame: Rect(origin: Point(x: 16, y: 376), size: Size(width: 370, height: 52)))
    private static let tree = AXNode(
        role: "AXApplication", frame: full, children: [button, status],
        screen: AXScreen(width: 402, height: 874, orientation: .portrait))

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func `should ask for the whole screen when nothing narrows the read`() throws {
        #expect(try DescribeUI.parse(x: nil, y: nil, short: false) == .screen)
    }

    @Test func `should ask for the short answer when a read is short`() throws {
        #expect(try DescribeUI.parse(x: nil, y: nil, short: true) == .short)
    }

    @Test func `should ask for one element when a read has a point`() throws {
        #expect(try DescribeUI.parse(x: 1, y: 2, short: false) == .point(Point(x: 1, y: 2)))
    }

    @Test func `should refuse a short read at a point`() {
        #expect(throws: DescribeUI.Refusal.self) { try DescribeUI.parse(x: 1, y: 2, short: true) }
    }

    @Test func `should refuse a point with only one coordinate`() {
        #expect(throws: DescribeUI.Refusal.self) { try DescribeUI.parse(x: 1, y: nil, short: false) }
        #expect(throws: DescribeUI.Refusal.self) { try DescribeUI.parse(x: nil, y: 2, short: false) }
    }

    @Test func `should read the screen for a short read`() throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(Self.tree)

        #expect(try DescribeUI.short.read(from: ax) == Self.tree)
    }

    @Test func `should read one element for a point`() throws {
        let ax = MockAccessibility()
        given(ax).describeAt(point: .any).willReturn(Self.button)

        #expect(try DescribeUI.point(Point(x: 1, y: 2)).read(from: ax) == Self.button)
    }

    @Test func `should answer a short read with what can be done and what the screen says`() throws {
        let answer = try object(DescribeUI.short.json(of: Self.tree, style: .wire))

        #expect(offeredNames(answer, "tap") == ["Sign In"])
        #expect(answer["text"] as? [String] == ["Not signed in"])
    }

    @Test func `should leave how to act out of a short read`() throws {
        let style = AXAffordance.Style.commandLine(program: "baguette", udid: "U", deviceSet: nil)

        let answer = try object(DescribeUI.short.json(of: Self.tree, style: style))

        #expect(answer["how"] == nil)
        #expect(answer["children"] == nil)
    }

    @Test func `should keep the whole tree when a read isn't short`() throws {
        let answer = try object(DescribeUI.screen.json(of: Self.tree, style: .wire))

        #expect((answer["children"] as? [Any])?.count == 2)
        #expect(answer["how"] == nil)
    }

    @Test func `should carry the tree on the wire when a read isn't short`() throws {
        let answer = try object("{" + DescribeUI.screen.wireFields(of: Self.tree) + "}")

        #expect(answer["tree"] != nil)
        #expect(answer["affordances"] != nil)
    }

    @Test func `should carry only the short answer on the wire when a read is short`() throws {
        let answer = try object("{" + DescribeUI.short.wireFields(of: Self.tree) + "}")

        #expect(answer["tree"] == nil)
        #expect(answer["how"] == nil)
        #expect(answer["text"] as? [String] == ["Not signed in"])
    }
}
