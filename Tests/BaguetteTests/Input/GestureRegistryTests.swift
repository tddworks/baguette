import Testing
@testable import Baguette

@Suite("GestureRegistry")
struct GestureRegistryTests {

    @Test func `parses tap by wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "tap", "x": 1, "y": 2, "width": 3, "height": 4
        ])
        #expect(g is Tap)
    }

    @Test func `parses swipe by wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "swipe",
            "startX": 0, "startY": 0, "endX": 1, "endY": 1,
            "width": 1, "height": 1
        ])
        #expect(g is Swipe)
    }

    @Test func `parses button by wire type`() throws {
        let g = try GestureRegistry.standard.parse(["type": "button", "button": "home"])
        #expect(g is Press)
    }

    @Test func `parses scroll by wire type`() throws {
        let g = try GestureRegistry.standard.parse(["type": "scroll", "deltaX": 5, "deltaY": -2])
        #expect(g is Scroll)
    }

    @Test func `parses pinch by wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "pinch",
            "cx": 100, "cy": 200, "startSpread": 60, "endSpread": 240,
            "width": 393, "height": 852
        ])
        #expect(g is Pinch)
    }

    @Test func `parses pan by wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "pan",
            "x1": 0, "y1": 0, "x2": 100, "y2": 0, "dx": 0, "dy": 100,
            "width": 393, "height": 852
        ])
        #expect(g is Pan)
    }

    @Test func `parses touch1-down with phase suffix`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch1-down", "x": 0, "y": 0, "width": 1, "height": 1
        ])
        let touch1 = try #require(g as? Touch1)
        #expect(touch1.phase == .down)
    }

    @Test func `parses touch1-move with phase suffix`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch1-move", "x": 0, "y": 0, "width": 1, "height": 1
        ])
        #expect((g as? Touch1)?.phase == .move)
    }

    @Test func `parses touch1-up with phase suffix`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch1-up", "x": 0, "y": 0, "width": 1, "height": 1
        ])
        #expect((g as? Touch1)?.phase == .up)
    }

    @Test func `parses touch2-down with phase suffix`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch2-down",
            "x1": 0, "y1": 0, "x2": 1, "y2": 1, "width": 1, "height": 1
        ])
        let touch2 = try #require(g as? Touch2)
        #expect(touch2.phase == .down)
    }

    @Test func `throws unknownKind on unknown wire type`() {
        #expect(throws: GestureError.unknownKind("frobnicate")) {
            _ = try GestureRegistry.standard.parse(["type": "frobnicate"])
        }
    }

    @Test func `throws missingField when type is missing`() {
        #expect(throws: GestureError.missingField("type")) {
            _ = try GestureRegistry.standard.parse([:])
        }
    }
}
