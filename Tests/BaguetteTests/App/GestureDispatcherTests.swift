import Testing
import Mockable
@testable import Baguette
@testable import BaguetteDevice

@Suite("GestureDispatcher")
struct GestureDispatcherTests {

    @Test func `should ack ok when a valid tap lands`() {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":100,"height":200}"#)

        #expect(ack == #"{"ok":true}"#)
    }

    @Test func `should ack not ok when the simulator refuses the gesture`() {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(false)
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":1,"height":1}"#)

        #expect(ack == #"{"ok":false}"#)
    }

    // The exact stdin line from issue #75 — a CarPlay nav-bar button
    // sits in the top band, and the edge hint has to survive the whole
    // way from the wire to the input surface for it to be pressed.
    @Test func `should carry a tap's edge hint all the way to the simulator`() {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(
            line: #"{"type":"tap","x":742,"y":44,"width":800,"height":480,"edge":"top"}"#
        )

        #expect(ack == #"{"ok":true}"#)
        verify(input.touch).tap(
            at: .value(Point(x: 742, y: 44)), size: .any, duration: .any, edge: .value(.top)
        ).called(1)
    }

    @Test func `should reject a gesture whose size is not the expected screen before touching the simulator`() throws {
        let input = InputMocks()
        let expected = try ExpectedScreen(json: ExpectedScreenTests.json)
        let screenGuard = InputScreenGuard(expected: expected) { expected.screen }
        let dispatcher = GestureDispatcher(input: input.abilities, screenGuard: screenGuard)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":1206,"height":2622}"#)

        #expect(ack == #"{"ok":false,"error":"input dimensions must match the observed native panel points"}"#)
        verify(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).called(0)
    }

    @Test func `should name the screen change when the guarded screen refuses a gesture`() throws {
        let input = InputMocks()
        let expected = try ExpectedScreen(json: ExpectedScreenTests.json)
        let screenGuard = InputScreenGuard(expected: expected) { throw ObservedScreenError.unavailable }
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any)
            .willProduce { _, _, _, _ in screenGuard.allows(.down) }
        let dispatcher = GestureDispatcher(input: input.abilities, screenGuard: screenGuard)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":402,"height":874}"#)

        #expect(ack == #"{"ok":false,"error":"the display cannot provide a fresh screen target"}"#)
    }

    @Test func `should report the missing field when a gesture line is incomplete`() {
        let input = InputMocks()
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1}"#)

        #expect(ack == #"{"ok":false,"error":"missing field: y"}"#)
    }

    @Test func `should report an unknown gesture type`() {
        let input = InputMocks()
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(line: #"{"type":"frobnicate"}"#)

        #expect(ack == #"{"ok":false,"error":"unknown kind: frobnicate"}"#)
    }

    @Test func `should report invalid JSON when a gesture line is malformed`() {
        let input = InputMocks()
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(line: "not json at all")

        #expect(ack == #"{"ok":false,"error":"invalid JSON"}"#)
    }

    @Test func `should land a touch1-down as the down phase of a single finger`() {
        let input = InputMocks()
        given(input.touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input.abilities)

        let ack = dispatcher.dispatch(line: #"{"type":"touch1-down","x":0,"y":0,"width":1,"height":1}"#)

        #expect(ack == #"{"ok":true}"#)
        verify(input.touch).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).called(1)
    }

    @Test func `should report any error a gesture fails to parse with in the ack`() {
        let input = InputMocks()
        let registry = GestureRegistry()
        registry.register(ThrowingGesture.self)
        let dispatcher = GestureDispatcher(input: input.abilities, registry: registry)

        let ack = dispatcher.dispatch(line: #"{"type":"explode"}"#)

        #expect(ack == #"{"ok":false,"error":"boom"}"#)
    }

    @Test func `should escape error text so the ack stays valid JSON`() {
        let input = InputMocks()
        let registry = GestureRegistry()
        registry.register(EscapingGesture.self)
        let dispatcher = GestureDispatcher(input: input.abilities, registry: registry)

        let ack = dispatcher.dispatch(line: #"{"type":"escape-error"}"#)

        #expect(ack == #"{"ok":false,"error":"quote \" backslash \\ newline \n tab \t backspace \b formfeed \f control \u0001"}"#)
    }
}

private struct ThrowingGesture: Gesture {
    static var wireType: String { "explode" }
    static func parse(_ dict: [String: Any]) throws -> Self { throw OtherError.boom }
    static var ability: Ability<any Touch> { .touch }
    func execute(on touch: any Touch) -> Bool { true }
}

private enum OtherError: Error, CustomStringConvertible {
    case boom
    var description: String { "boom" }
}

private struct EscapingGesture: Gesture {
    static var wireType: String { "escape-error" }
    static func parse(_ dict: [String: Any]) throws -> Self { throw EscapingError() }
    static var ability: Ability<any Touch> { .touch }
    func execute(on touch: any Touch) -> Bool { true }
}

private struct EscapingError: Error, CustomStringConvertible {
    var description: String {
        "quote \" backslash \\ newline \n tab \t backspace \u{08} formfeed \u{0C} control \u{01}"
    }
}
