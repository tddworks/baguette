import Testing
import Mockable
@testable import Baguette
@testable import BaguetteDevice

// MARK: - Tap

@Suite("Tap")
struct TapTests {
    @Test func `should read a tap's point, size and duration`() throws {
        let gesture = try Tap.parse([
            "x": 10.0, "y": 20.0, "width": 100.0, "height": 200.0, "duration": 0.1
        ])
        #expect(gesture == Tap(at: Point(x: 10, y: 20),
                                size: Size(width: 100, height: 200),
                                duration: 0.1))
    }

    @Test func `should hold a tap for 50ms when no duration is given`() throws {
        let gesture = try Tap.parse(["x": 0, "y": 0, "width": 1, "height": 1])
        #expect(gesture.duration == 0.05)
    }

    @Test func `should tap the simulator at the given point, size and duration`() {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let tap = Tap(at: Point(x: 5, y: 6), size: Size(width: 100, height: 200), duration: 0.07)

        #expect(tap.execute(on: input))
        verify(input.touch).tap(
            at: .value(Point(x: 5, y: 6)),
            size: .value(Size(width: 100, height: 200)),
            duration: .value(0.07),
            edge: .value(nil)
        ).called(1)
    }

    // A one-shot tap can name the screen edge it starts on, exactly
    // like the streaming touch path already does. Without it the CLI
    // could not express what the browser's touch source sends for the
    // same point — see issue #75.
    @Test func `should read the screen edge a tap starts on`() throws {
        let gesture = try Tap.parse([
            "x": 742, "y": 44, "width": 800, "height": 480, "edge": "top"
        ])
        #expect(gesture == Tap(at: Point(x: 742, y: 44),
                               size: Size(width: 800, height: 480),
                               duration: 0.05,
                               edge: .top))
    }

    @Test func `should leave a tap's edge unset when none is given`() throws {
        #expect(try Tap.parse(["x": 0, "y": 0, "width": 1, "height": 1]).edge == nil)
    }

    // A typo must not silently become an interior tap — that is the
    // exact swallowed-tap failure the edge hint exists to cure.
    @Test func `should reject a tap when its edge is unrecognised`() {
        #expect(throws: GestureError.invalidValue("edge", expected: "left | top | right | bottom")) {
            try Tap.parse(["x": 0, "y": 0, "width": 1, "height": 1, "edge": "Top"])
        }
    }

    @Test func `should tap the simulator from the named screen edge when an edge is given`() {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let tap = Tap(at: Point(x: 742, y: 44),
                      size: Size(width: 800, height: 480),
                      duration: 0.05,
                      edge: .top)

        #expect(tap.execute(on: input))
        verify(input.touch).tap(
            at: .value(Point(x: 742, y: 44)),
            size: .value(Size(width: 800, height: 480)),
            duration: .value(0.05),
            edge: .value(.top)
        ).called(1)
    }
}

// MARK: - Swipe

@Suite("Swipe")
struct SwipeTests {
    @Test func `should read a swipe's start, end, size and duration`() throws {
        let g = try Swipe.parse([
            "startX": 1, "startY": 2, "endX": 3, "endY": 4,
            "width": 100, "height": 200, "duration": 0.3
        ])
        #expect(g == Swipe(from: Point(x: 1, y: 2),
                           to:   Point(x: 3, y: 4),
                           size: Size(width: 100, height: 200),
                           duration: 0.3))
    }

    @Test func `should take 250ms over a swipe when no duration is given`() throws {
        let g = try Swipe.parse([
            "startX": 0, "startY": 0, "endX": 1, "endY": 1, "width": 1, "height": 1
        ])
        #expect(g.duration == 0.25)
    }

    @Test func `should swipe the simulator between the given points`() {
        let input = InputMocks()
        given(input.touch).swipe(from: .any, to: .any, size: .any, duration: .any).willReturn(true)
        let g = Swipe(from: .init(x: 0, y: 0), to: .init(x: 10, y: 10),
                      size: Size(width: 100, height: 200), duration: 0.2)

        _ = g.execute(on: input)
        verify(input.touch).swipe(
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
    @Test func `should read a one-finger touch's phase, point and size`() throws {
        let g = try Touch1.parse([
            "phase": "move", "x": 1, "y": 2, "width": 3, "height": 4
        ])
        #expect(g == Touch1(phase: .move, at: Point(x: 1, y: 2), size: Size(width: 3, height: 4)))
    }

    @Test func `should reject a one-finger touch when its phase is unknown`() {
        #expect(throws: GestureError.invalidValue("phase", expected: "down | move | up")) {
            try Touch1.parse(["phase": "wat", "x": 0, "y": 0, "width": 1, "height": 1])
        }
    }

    @Test func `should touch the simulator with one finger at the given phase and point`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
        let g = Touch1(phase: .up, at: Point(x: 5, y: 6), size: Size(width: 100, height: 200))

        _ = g.execute(on: input)
        verify(input.touch).touch1(
            phase: .value(.up),
            at:    .value(Point(x: 5, y: 6)),
            size:  .value(Size(width: 100, height: 200)),
            edge:  .value(nil)
        ).called(1)
    }

    @Test func `should read the screen edge a one-finger touch starts on`() throws {
        let g = try Touch1.parse([
            "phase": "down", "x": 0.5, "y": 0.99,
            "width": 100, "height": 200, "edge": "bottom"
        ])
        #expect(g == Touch1(phase: .down,
                            at: Point(x: 0.5, y: 0.99),
                            size: Size(width: 100, height: 200),
                            edge: .bottom))
    }

    @Test func `should reject a one-finger touch when its edge is unrecognised`() {
        #expect(throws: GestureError.invalidValue("edge", expected: "left | top | right | bottom")) {
            try Touch1.parse(["phase": "down", "x": 0, "y": 0, "width": 1, "height": 1, "edge": "Bottom"])
        }
    }

    @Test func `should touch the simulator with one finger from the named screen edge when an edge is given`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
        let g = Touch1(phase: .down,
                       at: Point(x: 0.5, y: 0.99),
                       size: Size(width: 100, height: 200),
                       edge: .bottom)

        _ = g.execute(on: input)
        verify(input.touch).touch1(
            phase: .value(.down),
            at:    .value(Point(x: 0.5, y: 0.99)),
            size:  .value(Size(width: 100, height: 200)),
            edge:  .value(.bottom)
        ).called(1)
    }
}

// MARK: - Touch2

@Suite("Touch2")
struct Touch2Tests {
    @Test func `should read a two-finger touch's phase, both points and size`() throws {
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

    @Test func `should touch the simulator with two fingers at the given phase and points`() {
        let input = InputMocks()
        given(input.touch).touch2(phase: .any, first: .any, second: .any, size: .any).willReturn(true)
        let g = Touch2(phase: .move,
                       first:  Point(x: 1, y: 1),
                       second: Point(x: 2, y: 2),
                       size: Size(width: 100, height: 200))

        _ = g.execute(on: input)
        verify(input.touch).touch2(
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
    @Test func `should toggle the software keyboard when the input accepts the request`() throws {
        let gesture = try ButtonPress.parse(["button": "software-keyboard"])
        let input = InputMocks()
        given(input.press).button(.value(.navigation(.softwareKeyboard)), duration: .value(0)).willReturn(true)

        #expect(gesture.execute(on: input))
        verify(input.press).button(.value(.navigation(.softwareKeyboard)), duration: .value(0)).called(1)
    }

    @Test func `should report failure when the software keyboard request is rejected`() throws {
        let gesture = try ButtonPress.parse(["button": "software-keyboard"])
        let input = InputMocks()
        given(input.press).button(.value(.navigation(.softwareKeyboard)), duration: .value(0)).willReturn(false)

        #expect(!gesture.execute(on: input))
    }

    @Test func `should read a home button press`() throws {
        let g = try ButtonPress.parse(["button": "home"])
        #expect(g == ButtonPress(button: .navigation(.home)))
    }

    @Test func `should read a lock button press`() throws {
        let g = try ButtonPress.parse(["button": "lock"])
        #expect(g == ButtonPress(button: .hardware(.lock)))
    }

    @Test func `should read a power button press`() throws {
        let g = try ButtonPress.parse(["button": "power"])
        #expect(g == ButtonPress(button: .hardware(.power)))
    }

    @Test func `should read a volume-up button press`() throws {
        let g = try ButtonPress.parse(["button": "volume-up"])
        #expect(g == ButtonPress(button: .hardware(.volumeUp)))
    }

    @Test func `should read a volume-down button press`() throws {
        let g = try ButtonPress.parse(["button": "volume-down"])
        #expect(g == ButtonPress(button: .hardware(.volumeDown)))
    }

    @Test func `should read an action button press`() throws {
        let g = try ButtonPress.parse(["button": "action"])
        #expect(g == ButtonPress(button: .hardware(.action)))
    }

    @Test func `should read an app-switcher button press`() throws {
        let g = try ButtonPress.parse(["button": "app-switcher"])
        #expect(g == ButtonPress(button: .navigation(.appSwitcher)))
    }

    @Test func `should read a swipe-to-app-switcher button press`() throws {
        let g = try ButtonPress.parse(["button": "swipe-to-app-switcher"])
        #expect(g == ButtonPress(button: .navigation(.swipeToAppSwitcher)))
    }

    @Test func `should read a swipe-to-home button press`() throws {
        let g = try ButtonPress.parse(["button": "swipe-to-home"])
        #expect(g == ButtonPress(button: .navigation(.swipeToHome)))
    }

    @Test func `should read a pull-down-to-lock-screen button press`() throws {
        let g = try ButtonPress.parse(["button": "pull-down-to-lock-screen"])
        #expect(g == ButtonPress(button: .navigation(.pullDownToLockScreen)))
    }

    @Test func `should read a pull-down-to-notification-center button press`() throws {
        let g = try ButtonPress.parse(["button": "pull-down-to-notification-center"])
        #expect(g == ButtonPress(button: .navigation(.pullDownToNotificationCenter)))
    }

    @Test func `should read a button's hold duration when one is given`() throws {
        let g = try ButtonPress.parse(["button": "action", "duration": 1.5])
        #expect(g == ButtonPress(button: .hardware(.action), duration: 1.5))
    }

    @Test func `should hold a button for no time when no duration is given`() throws {
        let g = try ButtonPress.parse(["button": "home"])
        #expect(g.duration == 0)
    }

    @Test func `should read a digital-crown button press`() throws {
        let g = try ButtonPress.parse(["button": "digital-crown"])
        #expect(g == ButtonPress(button: .hardware(.digitalCrown)))
    }

    @Test func `should read a side-button button press`() throws {
        let g = try ButtonPress.parse(["button": "side-button"])
        #expect(g == ButtonPress(button: .hardware(.sideButton)))
    }

    @Test func `should read a left-side-button button press`() throws {
        let g = try ButtonPress.parse(["button": "left-side-button"])
        #expect(g == ButtonPress(button: .hardware(.leftSideButton)))
    }

    @Test func `should reject a press when the button is unknown`() {
        #expect(throws: GestureError.invalidValue(
            "button",
            expected: "home | app-switcher | swipe-to-app-switcher | swipe-to-home | pull-down-to-lock-screen | pull-down-to-notification-center | software-keyboard | back | lock | power | action | volume-up | volume-down | digital-crown | side-button | left-side-button"
        )) {
            try ButtonPress.parse(["button": "siri"])
        }
    }

    @Test func `should press the named button on the simulator`() {
        let input = InputMocks()
        given(input.press).button(.any, duration: .any).willReturn(true)

        _ = ButtonPress(button: .navigation(.home)).execute(on: input)
        verify(input.press).button(.value(.navigation(.home)), duration: .value(0)).called(1)
    }

    @Test func `should hold the button on the simulator for the given duration`() {
        let input = InputMocks()
        given(input.press).button(.any, duration: .any).willReturn(true)

        _ = ButtonPress(button: .hardware(.action), duration: 2.0).execute(on: input)
        verify(input.press).button(.value(.hardware(.action)), duration: .value(2.0)).called(1)
    }
}

// MARK: - DeviceButton

@Suite("DeviceButton")
struct DeviceButtonTests {
    @Test func `should give lock no standard HID usage, as it is a button message of its own`() {
        #expect(HardwareButton.lock.standardHIDUsage == nil)
    }

    @Test func `should give iPhone hardware buttons their standard HID codes`() {
        #expect(HardwareButton.power.standardHIDUsage      == HIDUsage(page: 12, usage: 48))
        #expect(HardwareButton.volumeUp.standardHIDUsage   == HIDUsage(page: 12, usage: 233))
        #expect(HardwareButton.volumeDown.standardHIDUsage == HIDUsage(page: 12, usage: 234))
        #expect(HardwareButton.action.standardHIDUsage     == HIDUsage(page: 11, usage: 45))
    }

    // Apple Watch hardware buttons. Codes copied verbatim from
    // /Library/Developer/DeviceKit/Chrome/watch4.devicechrome's
    // chrome.json — `usagePage` + `usage` per input. Side-button uses
    // the consumer "Information" usage (149), distinct from iPhone
    // power (48); the action button rides Apple's vendor-defined
    // page 0xFF01 (65281) usage 512.
    @Test func `should give Apple Watch hardware buttons their chrome HID codes`() {
        #expect(HardwareButton.digitalCrown.standardHIDUsage
            == HIDUsage(page: 12, usage: 64))
        #expect(HardwareButton.sideButton.standardHIDUsage
            == HIDUsage(page: 12, usage: 149))
        #expect(HardwareButton.leftSideButton.standardHIDUsage
            == HIDUsage(page: 65281, usage: 512))
    }

    @Test func `should name Apple Watch buttons as the watch chrome does`() {
        #expect(DeviceButton.hardware(.digitalCrown).rawValue   == "digital-crown")
        #expect(DeviceButton.hardware(.sideButton).rawValue     == "side-button")
        #expect(DeviceButton.hardware(.leftSideButton).rawValue == "left-side-button")
    }

    @Test func `should press a button on the simulator for the given duration`() {
        let input = InputMocks()
        given(input.press).button(.any, duration: .any).willReturn(true)

        DeviceButton.hardware(.action).press(duration: 1.5, on: input)
        verify(input.press).button(.value(.hardware(.action)), duration: .value(1.5)).called(1)
    }

    @Test func `should press a button on the simulator with no hold when no duration is given`() {
        let input = InputMocks()
        given(input.press).button(.any, duration: .any).willReturn(true)

        DeviceButton.navigation(.home).press(on: input)
        verify(input.press).button(.value(.navigation(.home)), duration: .value(0)).called(1)
    }
}

// MARK: - Scroll

@Suite("Scroll")
struct ScrollTests {
    @Test func `should read a scroll's horizontal and vertical deltas`() throws {
        let g = try WheelEvent.parse(["deltaX": 1, "deltaY": -2])
        #expect(g == WheelEvent(deltaX: 1, deltaY: -2))
    }

    @Test func `should scroll by nothing when no deltas are given`() throws {
        let g = try WheelEvent.parse([:])
        #expect(g == WheelEvent(deltaX: 0, deltaY: 0))
    }

    @Test func `should scroll the simulator by the given deltas`() {
        let input = InputMocks()
        given(input.scroll).scroll(deltaX: .any, deltaY: .any).willReturn(true)

        _ = WheelEvent(deltaX: 5, deltaY: -10).execute(on: input)
        verify(input.scroll).scroll(deltaX: .value(5), deltaY: .value(-10)).called(1)
    }
}

// MARK: - Pinch

@Suite("Pinch")
struct PinchTests {
    @Test func `should read a pinch's centre, spreads and size with a default duration`() throws {
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

    @Test func `should pinch as two fingers moving horizontally about the centre`() {
        let input = InputMocks()
        given(input.touch).twoFingerPath(
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
        verify(input.touch).twoFingerPath(
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
    @Test func `should reject a required number field when its value is not numeric`() {
        #expect(throws: GestureError.invalidValue("x", expected: "number")) {
            _ = try Field.requiredDouble(["x": "abc"], "x")
        }
    }

    @Test func `should reject a required text field when its value is not a string`() {
        #expect(throws: GestureError.invalidValue("name", expected: "string")) {
            _ = try Field.requiredString(["name": 42], "name")
        }
    }

    // `message` derives a CLI-friendly description for every case;
    // exhaustively assert all three so a future case-add fails the suite.
    @Test func `should describe every gesture error in a readable message`() {
        #expect(GestureError.missingField("x").message == "missing field: x")
        #expect(GestureError.invalidValue("x", expected: "number").message
                == "invalid x: expected number")
        #expect(GestureError.unknownKind("frob").message == "unknown kind: frob")
    }
}

// MARK: - Pan

@Suite("Pan")
struct PanTests {
    @Test func `should read a pan's two starting points, delta and size`() throws {
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

    @Test func `should pan as two fingers moving in parallel by the given delta`() {
        let input = InputMocks()
        given(input.touch).twoFingerPath(
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

        verify(input.touch).twoFingerPath(
            start1: .value(Point(x: 150, y: 500)),
            end1:   .value(Point(x: 150, y: 700)),
            start2: .value(Point(x: 250, y: 500)),
            end2:   .value(Point(x: 250, y: 700)),
            size: .value(Size(width: 393, height: 852)),
            duration: .value(0.5)
        ).called(1)
    }
}
