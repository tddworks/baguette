import Testing
@testable import Baguette

@Suite("GestureRegistry")
struct GestureRegistryTests {

    @Test func `should read a tap envelope by its wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "tap", "x": 1, "y": 2, "width": 3, "height": 4
        ])
        #expect(g is Tap)
    }

    @Test func `should read a swipe envelope by its wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "swipe",
            "startX": 0, "startY": 0, "endX": 1, "endY": 1,
            "width": 1, "height": 1
        ])
        #expect(g is Swipe)
    }

    @Test func `should read a button envelope as a press`() throws {
        let g = try GestureRegistry.standard.parse(["type": "button", "button": "home"])
        #expect(g is ButtonPress)
    }

    @Test func `should read a scroll envelope by its wire type`() throws {
        let g = try GestureRegistry.standard.parse(["type": "scroll", "deltaX": 5, "deltaY": -2])
        #expect(g is WheelEvent)
    }

    @Test func `should read a pinch envelope by its wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "pinch",
            "cx": 100, "cy": 200, "startSpread": 60, "endSpread": 240,
            "width": 393, "height": 852
        ])
        #expect(g is Pinch)
    }

    @Test func `should read a pan envelope by its wire type`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "pan",
            "x1": 0, "y1": 0, "x2": 100, "y2": 0, "dx": 0, "dy": 100,
            "width": 393, "height": 852
        ])
        #expect(g is Pan)
    }

    @Test func `should read touch1-down as a one-finger touch going down`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch1-down", "x": 0, "y": 0, "width": 1, "height": 1
        ])
        let touch1 = try #require(g as? Touch1)
        #expect(touch1.phase == .down)
    }

    @Test func `should read touch1-move as a one-finger touch moving`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch1-move", "x": 0, "y": 0, "width": 1, "height": 1
        ])
        #expect((g as? Touch1)?.phase == .move)
    }

    @Test func `should read touch1-up as a one-finger touch lifting`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch1-up", "x": 0, "y": 0, "width": 1, "height": 1
        ])
        #expect((g as? Touch1)?.phase == .up)
    }

    @Test func `should read touch2-down as a two-finger touch going down`() throws {
        let g = try GestureRegistry.standard.parse([
            "type": "touch2-down",
            "x1": 0, "y1": 0, "x2": 1, "y2": 1, "width": 1, "height": 1
        ])
        let touch2 = try #require(g as? Touch2)
        #expect(touch2.phase == .down)
    }

    @Test func `should reject an envelope when its wire type is unknown`() {
        #expect(throws: GestureError.unknownKind("frobnicate")) {
            _ = try GestureRegistry.standard.parse(["type": "frobnicate"])
        }
    }

    @Test func `should reject an envelope when its type is missing`() {
        #expect(throws: GestureError.missingField("type")) {
            _ = try GestureRegistry.standard.parse([:])
        }
    }

    // "tap-down" has a valid phase suffix but `tap` was registered
    // non-phased, so the phased path falls through; the literal
    // "tap-down" key has no parser → unknownKind. Pins the rule that a
    // dash + phase suffix is meaningful only for phased prefixes.
    @Test func `should reject a phase suffix as an unknown kind when the gesture has no phases`() {
        #expect(throws: GestureError.unknownKind("tap-down")) {
            _ = try GestureRegistry.standard.parse(["type": "tap-down"])
        }
    }

    @Test func `should reject an envelope when its type is not a string`() {
        #expect(throws: GestureError.invalidValue("type", expected: "string")) {
            _ = try GestureRegistry.standard.parse(["type": 42])
        }
    }
}
