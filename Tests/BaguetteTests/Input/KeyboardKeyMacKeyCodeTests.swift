import Testing
@testable import Baguette

/// HID-page-7 usage → macOS virtual-key-code translation. Drives the
/// `CGEventInput` keyboard path: `KeyboardKey` carries the HID usage
/// shared with iOS; we map it to a `UInt16` macOS virt-key the
/// adapter feeds into `CGEventCreateKeyboardEvent`.
@Suite("KeyboardKey.macKeyCode (HID usage → macOS virt-key)")
struct KeyboardKeyMacKeyCodeTests {

    // MARK: - letters (kVK_ANSI_*)

    @Test func `KeyA maps to kVK_ANSI_A (0)`() {
        #expect(KeyboardKey.from(wireCode: "KeyA")?.macKeyCode == 0)
    }

    @Test func `KeyZ maps to kVK_ANSI_Z (6)`() {
        // kVK_ANSI_Z is 6 — letter ordering in Carbon doesn't follow
        // HID order, so this catches a wrong identity-mapping.
        #expect(KeyboardKey.from(wireCode: "KeyZ")?.macKeyCode == 6)
    }

    @Test func `KeyS maps to kVK_ANSI_S (1)`() {
        #expect(KeyboardKey.from(wireCode: "KeyS")?.macKeyCode == 1)
    }

    // MARK: - digits

    @Test func `Digit1 maps to kVK_ANSI_1 (18)`() {
        #expect(KeyboardKey.from(wireCode: "Digit1")?.macKeyCode == 18)
    }

    @Test func `Digit0 maps to kVK_ANSI_0 (29)`() {
        #expect(KeyboardKey.from(wireCode: "Digit0")?.macKeyCode == 29)
    }

    // MARK: - control keys

    @Test func `Enter maps to kVK_Return (36)`() {
        #expect(KeyboardKey.from(wireCode: "Enter")?.macKeyCode == 36)
    }

    @Test func `Escape maps to kVK_Escape (53)`() {
        #expect(KeyboardKey.from(wireCode: "Escape")?.macKeyCode == 53)
    }

    @Test func `Backspace maps to kVK_Delete (51)`() {
        #expect(KeyboardKey.from(wireCode: "Backspace")?.macKeyCode == 51)
    }

    @Test func `Tab maps to kVK_Tab (48)`() {
        #expect(KeyboardKey.from(wireCode: "Tab")?.macKeyCode == 48)
    }

    @Test func `Space maps to kVK_Space (49)`() {
        #expect(KeyboardKey.from(wireCode: "Space")?.macKeyCode == 49)
    }

    // MARK: - arrows

    @Test func `arrow keys map to kVK_*Arrow`() {
        // Carbon: Left=123, Right=124, Down=125, Up=126.
        #expect(KeyboardKey.from(wireCode: "ArrowLeft")?.macKeyCode  == 123)
        #expect(KeyboardKey.from(wireCode: "ArrowRight")?.macKeyCode == 124)
        #expect(KeyboardKey.from(wireCode: "ArrowDown")?.macKeyCode  == 125)
        #expect(KeyboardKey.from(wireCode: "ArrowUp")?.macKeyCode    == 126)
    }

    // MARK: - punctuation

    @Test func `Minus and Equal map to their kVK_ANSI_ codes`() {
        #expect(KeyboardKey.from(wireCode: "Minus")?.macKeyCode == 27)
        #expect(KeyboardKey.from(wireCode: "Equal")?.macKeyCode == 24)
    }

    @Test func `Bracket and Backslash map to their kVK_ANSI_ codes`() {
        #expect(KeyboardKey.from(wireCode: "BracketLeft")?.macKeyCode  == 33)
        #expect(KeyboardKey.from(wireCode: "BracketRight")?.macKeyCode == 30)
        #expect(KeyboardKey.from(wireCode: "Backslash")?.macKeyCode    == 42)
    }

    // MARK: - unmapped

    @Test func `unmapped HID page returns nil`() {
        // A fabricated KeyboardKey on page 12 (consumer page, not
        // page 7) has no macOS virt-key equivalent.
        let weird = KeyboardKey(hidUsage: HIDUsage(page: 12, usage: 0x40))
        #expect(weird.macKeyCode == nil)
    }
}

@Suite("KeyModifier.cgEventFlag")
struct KeyModifierFlagTests {
    @Test func `each modifier maps to the matching CGEventFlag bit`() {
        // The four CGEventFlags bits we care about. We don't import
        // CoreGraphics here — Domain stays Foundation-only — so we
        // assert the raw UInt64 values that match Apple's docs.
        #expect(KeyModifier.shift.cgEventFlag   == 0x00020000)
        #expect(KeyModifier.control.cgEventFlag == 0x00040000)
        #expect(KeyModifier.option.cgEventFlag  == 0x00080000)
        #expect(KeyModifier.command.cgEventFlag == 0x00100000)
    }

    @Test func `combined modifiers OR their bits together`() {
        let combined = KeyModifier.combinedFlag(of: [.shift, .command])
        #expect(combined == (0x00020000 | 0x00100000))
    }

    @Test func `empty set produces zero flag`() {
        #expect(KeyModifier.combinedFlag(of: []) == 0)
    }
}
