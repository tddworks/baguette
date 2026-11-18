import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("Paste")
struct PasteTests {

    // MARK: - parse

    @Test func `should read the paste text and press Cmd+V by default`() throws {
        let p = try Paste.parse(["type": "paste", "text": "hello"])
        #expect(p.text == "hello")
        #expect(p.press == true)
    }

    @Test func `should read an explicit press false from a paste envelope`() throws {
        let p = try Paste.parse(["text": "hello", "press": false])
        #expect(p.press == false)
    }

    @Test func `should keep non-ASCII paste text verbatim`() throws {
        let p = try Paste.parse(["text": "héllo 🥖"])
        #expect(p.text == "héllo 🥖")
    }

    @Test func `should reject a paste envelope with no text`() {
        #expect(throws: GestureError.missingField("text")) {
            try Paste.parse([:])
        }
    }

    // MARK: - execute

    @Test func `should set the pasteboard text then press Cmd+V`() async throws {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any).willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let ok = try await Paste(text: "hello", press: true)
            .execute(pasteboard: pasteboard, input: input.abilities)

        #expect(ok == true)
        verify(pasteboard).setText(.value("hello")).called(1)
        verify(input.key).key(
            .value(KeyboardKey.from(wireCode: "KeyV")!),
            modifiers: .value([.command]),
            duration: .value(0)
        ).called(1)
    }

    @Test func `should set the pasteboard without a keystroke when press is false`() async throws {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any).willReturn(())

        let ok = try await Paste(text: "hello", press: false)
            .execute(pasteboard: pasteboard, input: input.abilities)

        #expect(ok == true)
        verify(pasteboard).setText(.value("hello")).called(1)
        verify(input.key).key(.any, modifiers: .any, duration: .any).called(0)
    }

    @Test func `should fail without pressing Cmd+V when the pasteboard cannot be set`() async {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any)
            .willThrow(PasteboardError.simctlFailed(status: 1))

        var caught: PasteboardError?
        do {
            _ = try await Paste(text: "hello", press: true)
                .execute(pasteboard: pasteboard, input: input.abilities)
        } catch {
            caught = error as? PasteboardError
        }

        #expect(caught == .simctlFailed(status: 1))
        verify(input.key).key(.any, modifiers: .any, duration: .any).called(0)
    }

    @Test func `should report not-ok when the Cmd+V press fails`() async throws {
        let pasteboard = MockPasteboard()
        let input = InputMocks()
        given(pasteboard).setText(.any).willReturn(())
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(false)

        let ok = try await Paste(text: "hello", press: true)
            .execute(pasteboard: pasteboard, input: input.abilities)
        #expect(ok == false)
    }
}
