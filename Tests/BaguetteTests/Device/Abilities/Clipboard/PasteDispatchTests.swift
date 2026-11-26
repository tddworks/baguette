import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `PasteDispatch` intercepts `paste` wire lines ahead of the gesture
/// registry on both entry points (`baguette input` stdin, serve WS) —
/// the same shape `describe_ui` uses. Anything that isn't a paste
/// line falls through untouched so `GestureDispatcher` keeps owning
/// gestures and error acks.
@Suite("PasteDispatch")
struct PasteDispatchTests {

    private func surfaces() -> (MockPasteboard, InputMocks) {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any).willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)
        return (pasteboard, input)
    }

    // MARK: - routing

    @Test func `should leave a line that is not a paste for the gesture pipeline`() async {
        let (pasteboard, input) = surfaces()
        for line in [
            #"{"type":"tap","x":1,"y":2,"width":390,"height":844}"#,
            "not json at all",
            #"{"no_type":true}"#,
        ] {
            let outcome = await PasteDispatch.dispatch(
                line: line, pasteboard: pasteboard, input: input.abilities
            )
            #expect(outcome == .notPaste)
        }
        verify(pasteboard).setText(.any).called(0)
    }

    @Test func `should set the pasteboard, press Cmd+V and ack ok for a paste line`() async {
        let (pasteboard, input) = surfaces()
        let outcome = await PasteDispatch.dispatch(
            line: #"{"type":"paste","text":"hello"}"#,
            pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .ok)
        verify(pasteboard).setText(.value("hello")).called(1)
        verify(input.key).key(.any, modifiers: .value([.command]), duration: .any).called(1)
    }

    @Test func `should paste using the pasteboard of the simulator`() async {
        let sim = MockSimulator()
        let (pasteboard, input) = surfaces()
        given(sim).pasteboard().willReturn(pasteboard)

        let outcome = await PasteDispatch.dispatch(
            line: #"{"type":"paste","text":"hi"}"#,
            pasteboard: sim.pasteboard(), input: input.abilities
        )
        #expect(outcome == .ok)
    }

    @Test func `should report the parse error and paste nothing when a paste line is malformed`() async {
        let (pasteboard, input) = surfaces()
        let outcome = await PasteDispatch.dispatch(
            line: #"{"type":"paste"}"#,
            pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .failed("missing field: text"))
        verify(pasteboard).setText(.any).called(0)
    }

    @Test func `should report a simctl failure when pasting`() async {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any)
            .willThrow(PasteboardError.simctlFailed(status: 1))

        let outcome = await PasteDispatch.dispatch(
            line: #"{"type":"paste","text":"hello"}"#,
            pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .failed("xcrun simctl pasteboard command exited 1"))
    }

    @Test func `should report a failed Cmd+V press when pasting`() async {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any).willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(false)

        let outcome = await PasteDispatch.dispatch(
            line: #"{"type":"paste","text":"hello"}"#,
            pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .failed("Cmd+V dispatch failed"))
    }

    // MARK: - projections

    @Test func `should answer a paste with a stdin ack and a paste_result frame`() {
        #expect(PasteDispatch.Outcome.notPaste.ackJSON == nil)
        #expect(PasteDispatch.Outcome.notPaste.resultFrame == nil)

        #expect(PasteDispatch.Outcome.ok.ackJSON == #"{"ok":true}"#)
        #expect(PasteDispatch.Outcome.ok.resultFrame
            == #"{"type":"paste_result","ok":true}"#)

        let failed = PasteDispatch.Outcome.failed("bad \"quote\"")
        #expect(failed.ackJSON == #"{"ok":false,"error":"bad \"quote\""}"#)
        #expect(failed.resultFrame
            == #"{"type":"paste_result","ok":false,"error":"bad \"quote\""}"#)
    }
}
