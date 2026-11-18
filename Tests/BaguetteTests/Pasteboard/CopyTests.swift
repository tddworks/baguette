import Testing
import Foundation
import Mockable
@testable import Baguette

/// The `copy` wire verb — the interactive mirror of `Paste`. Where
/// paste sets the pasteboard then presses Cmd+V, copy presses Cmd+C
/// (so the focused field copies its selection into the sim's
/// pasteboard), then ferries that pasteboard onto the host Mac
/// (`syncToHost`). `press:false` skips the keystroke for a pure ferry
/// of whatever the sim already holds.
@Suite("Copy")
struct CopyTests {

    private func surfaces() -> (MockPasteboard, InputMocks) {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).syncToHost().willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)
        return (pasteboard, input)
    }

    // MARK: - parse

    @Test func `should press Cmd+C by default when a copy envelope omits press`() {
        #expect(Copy.parse(["type": "copy"]) == Copy(press: true))
    }

    @Test func `should read an explicit press false from a copy envelope`() {
        #expect(Copy.parse(["type": "copy", "press": false]).press == false)
    }

    // MARK: - execute

    @Test func `should press Cmd+C then ferry the simulator pasteboard to the host`() async throws {
        let (pasteboard, input) = surfaces()
        let ok = try await Copy(press: true, settleNanos: 0)
            .execute(pasteboard: pasteboard, input: input.abilities)
        #expect(ok)
        verify(input.key).key(.any, modifiers: .value([.command]), duration: .any).called(1)
        verify(pasteboard).syncToHost().called(1)
    }

    @Test func `should only ferry the pasteboard, with no keystroke, when press is false`() async throws {
        let (pasteboard, input) = surfaces()
        let ok = try await Copy(press: false, settleNanos: 0)
            .execute(pasteboard: pasteboard, input: input.abilities)
        #expect(ok)
        verify(input.key).key(.any, modifiers: .any, duration: .any).called(0)
        verify(pasteboard).syncToHost().called(1)
    }

    @Test func `should still ferry the pasteboard but report not-ok when the Cmd+C press fails`() async throws {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).syncToHost().willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(false)

        let ok = try await Copy(press: true, settleNanos: 0)
            .execute(pasteboard: pasteboard, input: input.abilities)
        #expect(!ok)
        verify(pasteboard).syncToHost().called(1)
    }
}
