import Mockable
import Testing
@testable import BaguetteDevice

/// Typing on a device that has keys: each character its keystroke on the US
/// keyboard, held just long enough to land.
@Suite("KeystrokeTyping")
struct KeystrokeTypingTests {
    @Test func `should type each character as its key, shift where it needs`() {
        let key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(true)
        let keyA = KeyboardKey.from(wireCode: "KeyA")!

        #expect(KeystrokeTyping(key: key).type("Aa"))

        verify(key).key(.value(keyA), modifiers: .value([.shift]), duration: .any).called(1)
        verify(key).key(.value(keyA), modifiers: .value([]), duration: .any).called(1)
    }

    @Test func `should hold each typed key for 30 ms`() {
        let key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(true)

        _ = KeystrokeTyping(key: key).type("aB")

        verify(key).key(.any, modifiers: .any, duration: .value(0.03)).called(2)
    }

    @Test func `should type nothing, and succeed, when the text is empty`() {
        let key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(true)

        #expect(KeystrokeTyping(key: key).type(""))
        verify(key).key(.any, modifiers: .any, duration: .any).called(0)
    }

    @Test func `should refuse text the US keyboard can't type`() {
        let key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(true)

        #expect(!KeystrokeTyping(key: key).type("café"))
    }
}
