import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// `CopyDispatch` intercepts `copy` wire lines ahead of the gesture
/// registry on both entry points (`baguette input` stdin, serve WS) —
/// the mirror of `PasteDispatch`. Where paste rides text *into* the
/// sim, copy presses Cmd+C so the focused field copies its selection,
/// then ferries the sim's pasteboard *out* onto the host Mac
/// (`simctl pbsync <udid> host`), so it needs the async `Pasteboard`
/// AND the `Input` keystroke path. Anything that isn't a copy line
/// falls through untouched so `GestureDispatcher` keeps owning
/// gestures and error acks.
@Suite("CopyDispatch")
struct CopyDispatchTests {

    private func surfaces() -> (MockPasteboard, InputMocks) {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).syncToHost().willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)
        return (pasteboard, input)
    }

    // MARK: - routing

    @Test func `should leave a line that is not a copy for the gesture pipeline`() async {
        let (pasteboard, input) = surfaces()
        for line in [
            #"{"type":"tap","x":1,"y":2,"width":390,"height":844}"#,
            #"{"type":"paste","text":"hi"}"#,
            "not json at all",
            #"{"no_type":true}"#,
        ] {
            let outcome = await CopyDispatch.dispatch(
                line: line, pasteboard: pasteboard, input: input.abilities
            )
            #expect(outcome == .notCopy)
        }
        verify(pasteboard).syncToHost().called(0)
    }

    @Test func `should press Cmd+C, copy the simulator pasteboard to the host and ack ok for a copy line`() async {
        let (pasteboard, input) = surfaces()
        let outcome = await CopyDispatch.dispatch(
            line: #"{"type":"copy"}"#, pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .ok)
        verify(input.key).key(.any, modifiers: .value([.command]), duration: .any).called(1)
        verify(pasteboard).syncToHost().called(1)
    }

    @Test func `should copy to the host without a keystroke when press is false`() async {
        let (pasteboard, input) = surfaces()
        let outcome = await CopyDispatch.dispatch(
            line: #"{"type":"copy","press":false}"#, pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .ok)
        verify(input.key).key(.any, modifiers: .any, duration: .any).called(0)
        verify(pasteboard).syncToHost().called(1)
    }

    @Test func `should copy using the pasteboard and input of the simulator`() async {
        let sim = MockSimulator()
        let (pasteboard, input) = surfaces()
        given(sim).pasteboard().willReturn(pasteboard)
        given(sim).input().willReturn(input)

        let outcome = await CopyDispatch.dispatch(
            line: #"{"type":"copy"}"#, pasteboard: sim.pasteboard(), input: .input(of: "iPhone 17", all: sim.input())
        )
        #expect(outcome == .ok)
    }

    @Test func `should report a simctl failure when copying`() async {
        let input = InputMocks()
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)
        let pasteboard = MockPasteboard()
        given(pasteboard).syncToHost()
            .willThrow(PasteboardError.simctlFailed(status: 1))

        let outcome = await CopyDispatch.dispatch(
            line: #"{"type":"copy","press":false}"#, pasteboard: pasteboard, input: input.abilities
        )
        #expect(outcome == .failed("xcrun simctl pasteboard command exited 1"))
    }

    // MARK: - projections

    @Test func `should answer a copy with a stdin ack and a copy_result frame`() {
        #expect(CopyDispatch.Outcome.notCopy.ackJSON == nil)
        #expect(CopyDispatch.Outcome.notCopy.resultFrame == nil)

        #expect(CopyDispatch.Outcome.ok.ackJSON == #"{"ok":true}"#)
        #expect(CopyDispatch.Outcome.ok.resultFrame
            == #"{"type":"copy_result","ok":true}"#)

        let failed = CopyDispatch.Outcome.failed("bad \"quote\"")
        #expect(failed.ackJSON == #"{"ok":false,"error":"bad \"quote\""}"#)
        #expect(failed.resultFrame
            == #"{"type":"copy_result","ok":false,"error":"bad \"quote\""}"#)
    }
}
