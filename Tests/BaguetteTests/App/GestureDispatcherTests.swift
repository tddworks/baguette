import Testing
import Mockable
@testable import Baguette

@Suite("GestureDispatcher")
struct GestureDispatcherTests {

    @Test func `dispatches a valid tap and returns ok=true`() {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":100,"height":200}"#)

        #expect(ack == #"{"ok":true}"#)
    }

    @Test func `propagates the input surface's false return`() {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(false)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":1,"height":1}"#)

        #expect(ack == #"{"ok":false}"#)
    }

    // The exact stdin line from issue #75 — a CarPlay nav-bar button
    // sits in the top band, and the edge hint has to survive the whole
    // way from the wire to the input surface for it to be pressed.
    @Test func `carries a tap's edge hint through to the input surface`() {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(
            line: #"{"type":"tap","x":742,"y":44,"width":800,"height":480,"edge":"top"}"#
        )

        #expect(ack == #"{"ok":true}"#)
        verify(input).tap(
            at: .value(Point(x: 742, y: 44)), size: .any, duration: .any, edge: .value(.top)
        ).called(1)
    }

    @Test func `rejects an envelope whose size is not the expected screen before dispatching`() throws {
        let input = MockInput()
        let expected = try ExpectedScreen(json: ExpectedScreenTests.json)
        let screenGuard = InputScreenGuard(expected: expected) { expected.screen }
        let dispatcher = GestureDispatcher(input: input, screenGuard: screenGuard)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":1206,"height":2622}"#)

        #expect(ack == #"{"ok":false,"error":"input dimensions must match the observed native panel points"}"#)
        verify(input).tap(at: .any, size: .any, duration: .any, edge: .any).called(0)
    }

    @Test func `names the screen change when the guarded input surface refuses a gesture`() throws {
        let input = MockInput()
        let expected = try ExpectedScreen(json: ExpectedScreenTests.json)
        let screenGuard = InputScreenGuard(expected: expected) { throw ObservedScreenError.unavailable }
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any)
            .willProduce { _, _, _, _ in screenGuard.allows(.down) }
        let dispatcher = GestureDispatcher(input: input, screenGuard: screenGuard)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":402,"height":874}"#)

        #expect(ack == #"{"ok":false,"error":"the display cannot provide a fresh screen target"}"#)
    }

    @Test func `returns parse error on missing field`() {
        let input = MockInput()
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1}"#)

        #expect(ack == #"{"ok":false,"error":"missing field: y"}"#)
    }

    @Test func `returns parse error on unknown gesture type`() {
        let input = MockInput()
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"frobnicate"}"#)

        #expect(ack == #"{"ok":false,"error":"unknown kind: frobnicate"}"#)
    }

    @Test func `returns parse error on malformed JSON`() {
        let input = MockInput()
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: "not json at all")

        #expect(ack == #"{"ok":false,"error":"invalid JSON"}"#)
    }

    @Test func `dispatches phased touch1-down via registry suffix`() {
        let input = MockInput()
        given(input).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"touch1-down","x":0,"y":0,"width":1,"height":1}"#)

        #expect(ack == #"{"ok":true}"#)
        verify(input).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).called(1)
    }

    @Test func `wraps non-GestureError thrown by a parser into the ack`() {
        let input = MockInput()
        let registry = GestureRegistry()
        registry.register(ThrowingGesture.self)
        let dispatcher = GestureDispatcher(input: input, registry: registry)

        let ack = dispatcher.dispatch(line: #"{"type":"explode"}"#)

        #expect(ack == #"{"ok":false,"error":"boom"}"#)
    }

    @Test func `escapes thrown error strings in JSON acks`() {
        let input = MockInput()
        let registry = GestureRegistry()
        registry.register(EscapingGesture.self)
        let dispatcher = GestureDispatcher(input: input, registry: registry)

        let ack = dispatcher.dispatch(line: #"{"type":"escape-error"}"#)

        #expect(ack == #"{"ok":false,"error":"quote \" backslash \\ newline \n tab \t backspace \b formfeed \f control \u0001"}"#)
    }
}

private struct ThrowingGesture: Gesture {
    static var wireType: String { "explode" }
    static func parse(_ dict: [String: Any]) throws -> Self { throw OtherError.boom }
    func execute(on input: any Input) -> Bool { true }
}

private enum OtherError: Error, CustomStringConvertible {
    case boom
    var description: String { "boom" }
}

private struct EscapingGesture: Gesture {
    static var wireType: String { "escape-error" }
    static func parse(_ dict: [String: Any]) throws -> Self { throw EscapingError() }
    func execute(on input: any Input) -> Bool { true }
}

private struct EscapingError: Error, CustomStringConvertible {
    var description: String {
        "quote \" backslash \\ newline \n tab \t backspace \u{08} formfeed \u{0C} control \u{01}"
    }
}
