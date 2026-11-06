import Testing
import Foundation
import Mockable
@testable import Baguette

/// A `baguette input` session answers `fill` ahead of the gesture pipeline, as it
/// does `paste`. The rules are `Fill`'s; this only parses and serializes.
@Suite("FillDispatch")
struct FillDispatchTests {
    private static let full = Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874))
    private static let frame = Rect(origin: Point(x: 32, y: 183), size: Size(width: 338, height: 22))
    private static let tree = AXNode(
        role: "AXApplication", frame: full,
        children: [AXNode(role: "AXTextField", value: "gary", identifier: "email", frame: frame, focused: true)])
    private static let instant = Fill.Timing(find: 0, focus: 0, readBack: 0, poll: 0)

    private func dispatch(_ line: String) async -> String? {
        let ax = MockAccessibility()
        given(ax).glance().willReturn(Self.tree)
        given(ax).describeAll().willReturn(Self.tree)
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)
        return await FillDispatch.dispatch(
            line: line, accessibility: ax, pasteboard: MockPasteboard(), input: input, timing: Self.instant)
    }

    @Test func `should leave a line that isn't a fill for its own pipeline`() async {
        for line in [#"{"type":"type","text":"gary"}"#, "not json", #"{"label":"email"}"#] {
            #expect(await dispatch(line) == nil)
        }
    }

    @Test func `should answer a fill with what the field shows`() async {
        let answer = await dispatch(#"{"type":"fill","label":"email","text":"gary"}"#)
        #expect(answer == #"{"filled":"email","ok":true,"value":"gary"}"#)
    }

    @Test func `should answer a fill with no text as a refusal`() async throws {
        let answer = try #require(await dispatch(#"{"type":"fill","label":"email"}"#))
        #expect(answer.contains(#""ok":false"#))
        #expect(answer.contains("text"))
    }
}
