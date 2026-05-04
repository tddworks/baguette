import Testing
import Mockable
@testable import Baguette

// MARK: - Tap

@Suite("Tap")
struct TapTests {
    @Test func `parses x, y, size and optional duration`() throws {
        let gesture = try Tap.parse([
            "x": 10.0, "y": 20.0, "width": 100.0, "height": 200.0, "duration": 0.1
        ])
        #expect(gesture == Tap(at: Point(x: 10, y: 20),
                                size: Size(width: 100, height: 200),
                                duration: 0.1))
    }

    @Test func `defaults duration to 50ms when missing`() throws {
        let gesture = try Tap.parse(["x": 0, "y": 0, "width": 1, "height": 1])
        #expect(gesture.duration == 0.05)
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any).willReturn(true)
        let tap = Tap(at: Point(x: 5, y: 6), size: Size(width: 100, height: 200), duration: 0.07)

        #expect(tap.execute(on: input))
        verify(input).tap(
            at: .value(Point(x: 5, y: 6)),
            size: .value(Size(width: 100, height: 200)),
            duration: .value(0.07)
        ).called(1)
    }
}

// MARK: - Swipe

@Suite("Swipe")
struct SwipeTests {
    @Test func `parses start, end, size, optional duration`() throws {
        let g = try Swipe.parse([
            "startX": 1, "startY": 2, "endX": 3, "endY": 4,
            "width": 100, "height": 200, "duration": 0.3
        ])
        #expect(g == Swipe(from: Point(x: 1, y: 2),
                           to:   Point(x: 3, y: 4),
                           size: Size(width: 100, height: 200),
                           duration: 0.3))
    }

    @Test func `defaults duration to 250ms`() throws {
        let g = try Swipe.parse([
            "startX": 0, "startY": 0, "endX": 1, "endY": 1, "width": 1, "height": 1
        ])
        #expect(g.duration == 0.25)
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).swipe(from: .any, to: .any, size: .any, duration: .any).willReturn(true)
        let g = Swipe(from: .init(x: 0, y: 0), to: .init(x: 10, y: 10),
                      size: Size(width: 100, height: 200), duration: 0.2)

        _ = g.execute(on: input)
        verify(input).swipe(
            from: .value(Point(x: 0, y: 0)),
            to:   .value(Point(x: 10, y: 10)),
            size: .value(Size(width: 100, height: 200)),
            duration: .value(0.2)
        ).called(1)
    }
}

// MARK: - Touch1

@Suite("Touch1")
struct Touch1Tests {
    @Test func `parses phase, point, size`() throws {
        let g = try Touch1.parse([
            "phase": "move", "x": 1, "y": 2, "width": 3, "height": 4
        ])
        #expect(g == Touch1(phase: .move, at: Point(x: 1, y: 2), size: Size(width: 3, height: 4)))
    }

    @Test func `rejects unknown phase`() {
        #expect(throws: GestureError.invalidValue("phase", expected: "down | move | up")) {
            try Touch1.parse(["phase": "wat", "x": 0, "y": 0, "width": 1, "height": 1])
        }
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).touch1(phase: .any, at: .any, size: .any).willReturn(true)
        let g = Touch1(phase: .up, at: Point(x: 5, y: 6), size: Size(width: 100, height: 200))

        _ = g.execute(on: input)
        verify(input).touch1(
            phase: .value(.up),
            at:    .value(Point(x: 5, y: 6)),
            size:  .value(Size(width: 100, height: 200))
        ).called(1)
    }
}

// MARK: - Touch2

@Suite("Touch2")
struct Touch2Tests {
    @Test func `parses phase, two points, size`() throws {
        let g = try Touch2.parse([
            "phase": "down",
            "x1": 1, "y1": 2, "x2": 3, "y2": 4,
            "width": 100, "height": 200,
        ])
        #expect(g == Touch2(
            phase: .down,
            first:  Point(x: 1, y: 2),
            second: Point(x: 3, y: 4),
            size: Size(width: 100, height: 200)
        ))
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).touch2(phase: .any, first: .any, second: .any, size: .any).willReturn(true)
        let g = Touch2(phase: .move,
                       first:  Point(x: 1, y: 1),
                       second: Point(x: 2, y: 2),
                       size: Size(width: 100, height: 200))

        _ = g.execute(on: input)
        verify(input).touch2(
            phase:  .value(.move),
            first:  .value(Point(x: 1, y: 1)),
            second: .value(Point(x: 2, y: 2)),
            size:   .value(Size(width: 100, height: 200))
        ).called(1)
    }
}

// MARK: - Press

@Suite("Press")
struct PressTests {
    @Test func `parses home button`() throws {
        let g = try Press.parse(["button": "home"])
        #expect(g == Press(button: .home))
    }

    @Test func `parses lock button`() throws {
        let g = try Press.parse(["button": "lock"])
        #expect(g == Press(button: .lock))
    }

    @Test func `parses power button`() throws {
        let g = try Press.parse(["button": "power"])
        #expect(g == Press(button: .power))
    }

    @Test func `parses volume-up button`() throws {
        let g = try Press.parse(["button": "volume-up"])
        #expect(g == Press(button: .volumeUp))
    }

    @Test func `parses volume-down button`() throws {
        let g = try Press.parse(["button": "volume-down"])
        #expect(g == Press(button: .volumeDown))
    }

    @Test func `parses action button`() throws {
        let g = try Press.parse(["button": "action"])
        #expect(g == Press(button: .action))
    }

    @Test func `rejects unknown button`() {
        #expect(throws: GestureError.invalidValue(
            "button",
            expected: "home | lock | power | volume-up | volume-down | action"
        )) {
            try Press.parse(["button": "siri"])
        }
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).button(.any).willReturn(true)

        _ = Press(button: .home).execute(on: input)
        verify(input).button(.value(.home)).called(1)
    }
}

// MARK: - Scroll

@Suite("Scroll")
struct ScrollTests {
    @Test func `parses deltaX and deltaY`() throws {
        let g = try Scroll.parse(["deltaX": 1, "deltaY": -2])
        #expect(g == Scroll(deltaX: 1, deltaY: -2))
    }

    @Test func `defaults deltas to zero when missing`() throws {
        let g = try Scroll.parse([:])
        #expect(g == Scroll(deltaX: 0, deltaY: 0))
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).scroll(deltaX: .any, deltaY: .any).willReturn(true)

        _ = Scroll(deltaX: 5, deltaY: -10).execute(on: input)
        verify(input).scroll(deltaX: .value(5), deltaY: .value(-10)).called(1)
    }
}

// MARK: - Pinch

@Suite("Pinch")
struct PinchTests {
    @Test func `parses centre, spreads, size, default duration`() throws {
        let g = try Pinch.parse([
            "cx": 100, "cy": 200,
            "startSpread": 60, "endSpread": 240,
            "width": 393, "height": 852
        ])
        #expect(g == Pinch(center: Point(x: 100, y: 200),
                           startSpread: 60, endSpread: 240,
                           size: Size(width: 393, height: 852),
                           duration: 0.6))
    }

    @Test func `executes as a horizontal two-finger path centred on cx, cy`() {
        let input = MockInput()
        given(input).twoFingerPath(
            start1: .any, end1: .any, start2: .any, end2: .any,
            size: .any, duration: .any
        ).willReturn(true)

        let g = Pinch(center: Point(x: 100, y: 200),
                      startSpread: 60, endSpread: 240,
                      size: Size(width: 393, height: 852),
                      duration: 0.6)
        _ = g.execute(on: input)

        // start1 = 100 - 30 = 70; end1 = 100 - 120 = -20
        // start2 = 100 + 30 = 130; end2 = 100 + 120 = 220
        verify(input).twoFingerPath(
            start1: .value(Point(x: 70,  y: 200)),
            end1:   .value(Point(x: -20, y: 200)),
            start2: .value(Point(x: 130, y: 200)),
            end2:   .value(Point(x: 220, y: 200)),
            size: .value(Size(width: 393, height: 852)),
            duration: .value(0.6)
        ).called(1)
    }
}

// MARK: - Field

@Suite("Field")
struct FieldTests {
    @Test func `requiredDouble throws invalidValue for non-numeric input`() {
        #expect(throws: GestureError.invalidValue("x", expected: "number")) {
            _ = try Field.requiredDouble(["x": "abc"], "x")
        }
    }

    @Test func `requiredString throws invalidValue when value is not a string`() {
        #expect(throws: GestureError.invalidValue("name", expected: "string")) {
            _ = try Field.requiredString(["name": 42], "name")
        }
    }

    // `message` derives a CLI-friendly description for every case;
    // exhaustively assert all three so a future case-add fails the suite.
    @Test func `GestureError message covers all cases`() {
        #expect(GestureError.missingField("x").message == "missing field: x")
        #expect(GestureError.invalidValue("x", expected: "number").message
                == "invalid x: expected number")
        #expect(GestureError.unknownKind("frob").message == "unknown kind: frob")
    }
}

// MARK: - Pan

@Suite("Pan")
struct PanTests {
    @Test func `parses two starting points, delta, size`() throws {
        let g = try Pan.parse([
            "x1": 150, "y1": 500, "x2": 250, "y2": 500,
            "dx": 0, "dy": 200, "width": 393, "height": 852
        ])
        #expect(g == Pan(
            first:  Point(x: 150, y: 500),
            second: Point(x: 250, y: 500),
            dx: 0, dy: 200,
            size: Size(width: 393, height: 852),
            duration: 0.5
        ))
    }

    @Test func `executes as a parallel two-finger path translated by dx, dy`() {
        let input = MockInput()
        given(input).twoFingerPath(
            start1: .any, end1: .any, start2: .any, end2: .any,
            size: .any, duration: .any
        ).willReturn(true)

        let g = Pan(
            first:  Point(x: 150, y: 500),
            second: Point(x: 250, y: 500),
            dx: 0, dy: 200,
            size: Size(width: 393, height: 852),
            duration: 0.5
        )
        _ = g.execute(on: input)

        verify(input).twoFingerPath(
            start1: .value(Point(x: 150, y: 500)),
            end1:   .value(Point(x: 150, y: 700)),
            start2: .value(Point(x: 250, y: 500)),
            end2:   .value(Point(x: 250, y: 700)),
            size: .value(Size(width: 393, height: 852)),
            duration: .value(0.5)
        ).called(1)
    }
}
