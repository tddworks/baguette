import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("KeyboardKey")
struct KeyboardKeyTests {
    @Test func `parses lowercase letter wire codes onto HID page 7`() {
        // KeyA → 0x04, KeyB → 0x05, ..., KeyZ → 0x1D.
        #expect(KeyboardKey.from(wireCode: "KeyA")?.hidUsage == HIDUsage(page: 7, usage: 0x04))
        #expect(KeyboardKey.from(wireCode: "KeyM")?.hidUsage == HIDUsage(page: 7, usage: 0x10))
        #expect(KeyboardKey.from(wireCode: "KeyZ")?.hidUsage == HIDUsage(page: 7, usage: 0x1D))
    }

    @Test func `parses digit wire codes (1-9 then 0)`() {
        // HID quirk: Digit1 = 0x1E, Digit9 = 0x26, Digit0 = 0x27 (last).
        #expect(KeyboardKey.from(wireCode: "Digit1")?.hidUsage == HIDUsage(page: 7, usage: 0x1E))
        #expect(KeyboardKey.from(wireCode: "Digit9")?.hidUsage == HIDUsage(page: 7, usage: 0x26))
        #expect(KeyboardKey.from(wireCode: "Digit0")?.hidUsage == HIDUsage(page: 7, usage: 0x27))
    }

    @Test func `parses named special keys`() {
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

    @Test func `unknown wire code resolves to nil`() {
        #expect(KeyboardKey.from(wireCode: "F13")  == nil)
        #expect(KeyboardKey.from(wireCode: "")     == nil)
        #expect(KeyboardKey.from(wireCode: "keya") == nil)  // case-sensitive on purpose
    }
}

@Suite("KeyModifier")
struct KeyModifierTests {
    @Test func `each modifier carries its HID usage on page 7`() {
        #expect(KeyModifier.shift.hidUsage   == HIDUsage(page: 7, usage: 0xE1))
        #expect(KeyModifier.control.hidUsage == HIDUsage(page: 7, usage: 0xE0))
        #expect(KeyModifier.option.hidUsage  == HIDUsage(page: 7, usage: 0xE2))
        #expect(KeyModifier.command.hidUsage == HIDUsage(page: 7, usage: 0xE3))
    }

    @Test func `parses lowercase wire rawValues`() {
        #expect(KeyModifier(rawValue: "shift")   == .shift)
        #expect(KeyModifier(rawValue: "control") == .control)
        #expect(KeyModifier(rawValue: "option")  == .option)
        #expect(KeyModifier(rawValue: "command") == .command)
        #expect(KeyModifier(rawValue: "meta")    == nil)
    }
}

@Suite("KeyboardKey.decompose")
struct KeyboardKeyDecomposeTests {
    @Test func `lowercase letter has no modifier`() {
        let s = KeyboardKey.decompose(character: "a")
        #expect(s?.key.hidUsage == HIDUsage(page: 7, usage: 0x04))
        #expect(s?.modifiers == [])
    }

    @Test func `uppercase letter shifts the same key`() {
        let s = KeyboardKey.decompose(character: "A")
        #expect(s?.key.hidUsage == HIDUsage(page: 7, usage: 0x04))
        #expect(s?.modifiers == [.shift])
    }

    @Test func `digit has no modifier; shifted-digit symbols share its key`() {
        #expect(KeyboardKey.decompose(character: "1")?.modifiers == [])
        let bang = KeyboardKey.decompose(character: "!")
        #expect(bang?.key.hidUsage == HIDUsage(page: 7, usage: 0x1E))
        #expect(bang?.modifiers == [.shift])
    }

    @Test func `space is bare key 0x2C`() {
        let s = KeyboardKey.decompose(character: " ")
        #expect(s?.key.hidUsage == HIDUsage(page: 7, usage: 0x2C))
        #expect(s?.modifiers == [])
    }

    @Test func `common punctuation maps to its key plus shift when needed`() {
        // Period unshifted, '>' shifted.
        #expect(KeyboardKey.decompose(character: ".")?.modifiers == [])
        #expect(KeyboardKey.decompose(character: ">")?.modifiers == [.shift])
        #expect(KeyboardKey.decompose(character: ">")?.key.hidUsage
            == KeyboardKey.decompose(character: ".")?.key.hidUsage)
    }

    @Test func `non-ASCII character is unsupported`() {
        #expect(KeyboardKey.decompose(character: "é") == nil)
        #expect(KeyboardKey.decompose(character: "中") == nil)
        #expect(KeyboardKey.decompose(character: "🦄") == nil)
    }
}

// MARK: - Key gesture

@Suite("Key")
struct KeyGestureTests {
    @Test func `parses code without modifiers`() throws {
        let g = try Key.parse(["code": "KeyA"])
        #expect(g.key == KeyboardKey.from(wireCode: "KeyA"))
        #expect(g.modifiers == [])
        #expect(g.duration == 0)
    }

    @Test func `parses modifier list`() throws {
        let g = try Key.parse(["code": "KeyA", "modifiers": ["shift", "command"]])
        #expect(g.modifiers == Set([.shift, .command]))
    }

    @Test func `parses optional duration`() throws {
        let g = try Key.parse(["code": "Enter", "duration": 0.5])
        #expect(g.duration == 0.5)
    }

    @Test func `rejects unknown code`() {
        #expect(throws: GestureError.self) {
            try Key.parse(["code": "F13"])
        }
    }

    @Test func `rejects unknown modifier`() {
        #expect(throws: GestureError.self) {
            try Key.parse(["code": "KeyA", "modifiers": ["meta"]])
        }
    }

    @Test func `executes against the input surface`() {
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
    @Test func `parses text`() throws {
        let g = try TypeText.parse(["text": "hi"])
        #expect(g.text == "hi")
    }

    @Test func `rejects missing text`() {
        #expect(throws: GestureError.missingField("text")) {
            try TypeText.parse([:])
        }
    }

    @Test func `rejects text with unsupported characters`() {
        #expect(throws: GestureError.self) {
            try TypeText.parse(["text": "hi🦄"])
        }
    }

    @Test func `executes by emitting one key per character`() {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let keyA = KeyboardKey.from(wireCode: "KeyA")!
        _ = TypeText(text: "Aa").execute(on: input)

        verify(input).key(
            .value(keyA), modifiers: .value([.shift]), duration: .value(0)
        ).called(1)
        verify(input).key(
            .value(keyA), modifiers: .value([]), duration: .value(0)
        ).called(1)
    }

    @Test func `empty text is a no-op that succeeds`() {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        #expect(TypeText(text: "").execute(on: input) == true)
        verify(input).key(.any, modifiers: .any, duration: .any).called(0)
    }
}
