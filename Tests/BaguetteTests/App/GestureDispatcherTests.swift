import Testing
import Mockable
@testable import Baguette

@Suite("GestureDispatcher")
struct GestureDispatcherTests {

    @Test func `dispatches a valid tap and returns ok=true`() {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":100,"height":200}"#)

        #expect(ack == #"{"ok":true}"#)
    }

    @Test func `propagates the input surface's false return`() {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any).willReturn(false)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"tap","x":1,"y":2,"width":1,"height":1}"#)

        #expect(ack == #"{"ok":false}"#)
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
        given(input).touch1(phase: .any, at: .any, size: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: input)

        let ack = dispatcher.dispatch(line: #"{"type":"touch1-down","x":0,"y":0,"width":1,"height":1}"#)

        #expect(ack == #"{"ok":true}"#)
        verify(input).touch1(phase: .value(.down), at: .any, size: .any).called(1)
    }

    @Test func `wraps non-GestureError thrown by a parser into the ack`() {
        let input = MockInput()
        let registry = GestureRegistry()
        registry.register(ThrowingGesture.self)
        let dispatcher = GestureDispatcher(input: input, registry: registry)

        let ack = dispatcher.dispatch(line: #"{"type":"explode"}"#)

        #expect(ack == #"{"ok":false,"error":"boom"}"#)
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
