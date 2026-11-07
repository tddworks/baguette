import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("KeyboardKey")
struct KeyboardKeyTests {
    @Test func `should map letter key codes onto HID page 7`() {
        // KeyA → 0x04, KeyB → 0x05, ..., KeyZ → 0x1D.
        #expect(KeyboardKey.from(wireCode: "KeyA")?.hidUsage == HIDUsage(page: 7, usage: 0x04))
        #expect(KeyboardKey.from(wireCode: "KeyM")?.hidUsage == HIDUsage(page: 7, usage: 0x10))
        #expect(KeyboardKey.from(wireCode: "KeyZ")?.hidUsage == HIDUsage(page: 7, usage: 0x1D))
    }

    @Test func `should map digit key codes onto HID page 7 with 1 to 9 before 0`() {
        // HID quirk: Digit1 = 0x1E, Digit9 = 0x26, Digit0 = 0x27 (last).
        #expect(KeyboardKey.from(wireCode: "Digit1")?.hidUsage == HIDUsage(page: 7, usage: 0x1E))
        #expect(KeyboardKey.from(wireCode: "Digit9")?.hidUsage == HIDUsage(page: 7, usage: 0x26))
        #expect(KeyboardKey.from(wireCode: "Digit0")?.hidUsage == HIDUsage(page: 7, usage: 0x27))
    }

    @Test func `should map numpad key codes onto HID keypad usages`() {
        // Keypad block on HID page 7: 1-9 = 0x59..0x61, 0 = 0x62 (last,
        // like the top-row digit quirk), decimal = 0x63; the operators
        // and Enter (0x54..0x58) sit just below the digits, Equal (0x67)
        // above the decimal. NumLock is out of scope — iOS has no
        // num-lock concept.
        let pairs: [(String, UInt32)] = [
            ("Numpad1", 0x59), ("Numpad2", 0x5A), ("Numpad3", 0x5B),
            ("Numpad4", 0x5C), ("Numpad5", 0x5D), ("Numpad6", 0x5E),
            ("Numpad7", 0x5F), ("Numpad8", 0x60), ("Numpad9", 0x61),
            ("Numpad0", 0x62), ("NumpadDecimal", 0x63),
            ("NumpadDivide", 0x54), ("NumpadMultiply", 0x55),
            ("NumpadSubtract", 0x56), ("NumpadAdd", 0x57),
            ("NumpadEnter", 0x58), ("NumpadEqual", 0x67),
        ]
        for (code, expected) in pairs {
            #expect(KeyboardKey.from(wireCode: code)?.hidUsage == HIDUsage(page: 7, usage: expected))
        }
    }

    @Test func `should map named special keys onto HID page 7`() {
        let pairs: [(String, UInt32)] = [
            ("Enter", 0x28), ("Escape", 0x29), ("Backspace", 0x2A),
            ("Tab", 0x2B), ("Space", 0x2C),
            ("ArrowRight", 0x4F), ("ArrowLeft", 0x50),
            ("ArrowDown", 0x51), ("ArrowUp", 0x52),
        ]
        for (code, expected) in pairs {
            #expect(KeyboardKey.from(wireCode: code)?.hidUsage == HIDUsage(page: 7, usage: expected))
        }
    }

    @Test func `should recognise no key when the key code is unknown`() {
        #expect(KeyboardKey.from(wireCode: "F13")  == nil)
        #expect(KeyboardKey.from(wireCode: "")     == nil)
        #expect(KeyboardKey.from(wireCode: "keya") == nil)  // case-sensitive on purpose
    }
}

@Suite("KeyModifier")
struct KeyModifierTests {
    @Test func `should give each modifier its HID usage on page 7`() {
        #expect(KeyModifier.shift.hidUsage   == HIDUsage(page: 7, usage: 0xE1))
        #expect(KeyModifier.control.hidUsage == HIDUsage(page: 7, usage: 0xE0))
        #expect(KeyModifier.option.hidUsage  == HIDUsage(page: 7, usage: 0xE2))
        #expect(KeyModifier.command.hidUsage == HIDUsage(page: 7, usage: 0xE3))
    }

    @Test func `should recognise modifiers by their lowercase wire names`() {
        #expect(KeyModifier(rawValue: "shift")   == .shift)
        #expect(KeyModifier(rawValue: "control") == .control)
        #expect(KeyModifier(rawValue: "option")  == .option)
        #expect(KeyModifier(rawValue: "command") == .command)
        #expect(KeyModifier(rawValue: "meta")    == nil)
    }
}

@Suite("KeyboardKey.decompose")
struct KeyboardKeyDecomposeTests {
    @Test func `should type a lowercase letter with no modifier`() {
        let s = KeyboardKey.decompose(character: "a")
        #expect(s?.key.hidUsage == HIDUsage(page: 7, usage: 0x04))
        #expect(s?.modifiers == [])
    }

    @Test func `should type an uppercase letter as the same key with shift`() {
        let s = KeyboardKey.decompose(character: "A")
        #expect(s?.key.hidUsage == HIDUsage(page: 7, usage: 0x04))
        #expect(s?.modifiers == [.shift])
    }

    @Test func `should type a digit bare and its shifted symbol as the same key with shift`() {
        #expect(KeyboardKey.decompose(character: "1")?.modifiers == [])
        let bang = KeyboardKey.decompose(character: "!")
        #expect(bang?.key.hidUsage == HIDUsage(page: 7, usage: 0x1E))
        #expect(bang?.modifiers == [.shift])
    }

    @Test func `should type a space as the bare space key`() {
        let s = KeyboardKey.decompose(character: " ")
        #expect(s?.key.hidUsage == HIDUsage(page: 7, usage: 0x2C))
        #expect(s?.modifiers == [])
    }

    @Test func `should type punctuation as its key plus shift when needed`() {
        // Period unshifted, '>' shifted.
        #expect(KeyboardKey.decompose(character: ".")?.modifiers == [])
        #expect(KeyboardKey.decompose(character: ">")?.modifiers == [.shift])
        #expect(KeyboardKey.decompose(character: ">")?.key.hidUsage
            == KeyboardKey.decompose(character: ".")?.key.hidUsage)
    }

    @Test func `should find no key to type when the character is not ASCII`() {
        #expect(KeyboardKey.decompose(character: "é") == nil)
        #expect(KeyboardKey.decompose(character: "中") == nil)
        #expect(KeyboardKey.decompose(character: "🦄") == nil)
    }
}

// MARK: - Key gesture

@Suite("Key")
struct KeyGestureTests {
    @Test func `should read a key press with no modifiers and no hold`() throws {
        let g = try Key.parse(["code": "KeyA"])
        #expect(g.key == KeyboardKey.from(wireCode: "KeyA"))
        #expect(g.modifiers == [])
        #expect(g.duration == 0)
    }

    @Test func `should read a key press's modifiers`() throws {
        let g = try Key.parse(["code": "KeyA", "modifiers": ["shift", "command"]])
        #expect(g.modifiers == Set([.shift, .command]))
    }

    @Test func `should read a key press's hold duration`() throws {
        let g = try Key.parse(["code": "Enter", "duration": 0.5])
        #expect(g.duration == 0.5)
    }

    @Test func `should reject a key press when the key code is unknown`() {
        #expect(throws: GestureError.self) {
            try Key.parse(["code": "F13"])
        }
    }

    @Test func `should reject a key press when a modifier is unknown`() {
        #expect(throws: GestureError.self) {
            try Key.parse(["code": "KeyA", "modifiers": ["meta"]])
        }
    }

    @Test func `should press the key on the simulator with its modifiers and hold`() {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let key = KeyboardKey.from(wireCode: "KeyA")!
        _ = Key(key: key, modifiers: [.shift], duration: 0.1).execute(on: input)
        verify(input).key(
            .value(key),
            modifiers: .value([.shift]),
            duration: .value(0.1)
        ).called(1)
    }
}

// MARK: - TypeText gesture

@Suite("TypeText")
struct TypeTextGestureTests {
    @Test func `should be typeable when every character is on the US keyboard`() {
        #expect(TypeText(typeable: "gary@example.com")?.text == "gary@example.com")
    }

    @Test func `should not be typeable when a character isn't on the US keyboard`() {
        #expect(TypeText(typeable: "café") == nil)
    }

    @Test func `should hold each typed key for 30 ms`() {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        _ = TypeText(text: "aB").execute(on: input)

        verify(input).key(.any, modifiers: .any, duration: .value(0.03)).called(2)
    }

    @Test func `should keep a single key press at its own hold`() throws {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        _ = try Key.parse(["code": "KeyA"]).execute(on: input)

        verify(input).key(.any, modifiers: .any, duration: .value(0)).called(1)
    }

    @Test func `should read the text to type`() throws {
        let g = try TypeText.parse(["text": "hi"])
        #expect(g.text == "hi")
    }

    @Test func `should reject typing when no text is given`() {
        #expect(throws: GestureError.missingField("text")) {
            try TypeText.parse([:])
        }
    }

    @Test func `should reject typing when the text has unsupported characters`() {
        #expect(throws: GestureError.self) {
            try TypeText.parse(["text": "hi🦄"])
        }
    }

    @Test func `should type text as one key press per character`() {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let keyA = KeyboardKey.from(wireCode: "KeyA")!
        _ = TypeText(text: "Aa").execute(on: input)

        verify(input).key(
            .value(keyA), modifiers: .value([.shift]), duration: .any
        ).called(1)
        verify(input).key(
            .value(keyA), modifiers: .value([]), duration: .any
        ).called(1)
    }

    @Test func `should succeed without pressing anything when the text is empty`() {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        #expect(TypeText(text: "").execute(on: input) == true)
        verify(input).key(.any, modifiers: .any, duration: .any).called(0)
    }
}
