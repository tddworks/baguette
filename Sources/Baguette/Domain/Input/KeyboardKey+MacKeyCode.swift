import Foundation

/// HID-page-7 usage → macOS Carbon virtual-key-code translation.
///
/// `KeyboardKey` carries a `HIDUsage` that's shared with iOS (the
/// SimulatorKit HID path uses page-7 codes directly). On macOS,
/// `CGEventCreateKeyboardEvent` takes a `CGKeyCode` (UInt16) — a
/// completely different code space defined in Carbon's
/// `kVK_*` constants. The mapping is fixed for every US-keyboard
/// physical key; we encode it here so `CGEventInput` is a pure
/// "look up the code, post the event" pass-through with no
/// translation logic of its own.
///
/// Domain stays Foundation-only (no CoreGraphics import) — the
/// adapter casts the `UInt16` to `CGKeyCode` inline.
extension KeyboardKey {
    /// macOS Carbon virtual-key code for this key, or `nil` when the
    /// HID usage doesn't have a US-keyboard equivalent (e.g. a
    /// fabricated consumer-page button).
    var macKeyCode: UInt16? {
        guard hidUsage.page == 7 else { return nil }
        return Self.usageToMacKeyCode[hidUsage.usage]
    }

    /// Built once. Source: Carbon's `Events.h` (`kVK_ANSI_*`,
    /// `kVK_Return`, etc.) cross-referenced with the HID page-7
    /// usage table in `Keyboard.swift`.
    private static let usageToMacKeyCode: [UInt32: UInt16] = [
        // Letters — HID 0x04 (KeyA) → kVK_ANSI_A (0). Carbon's letter
        // ordering doesn't match HID's, so this table is exhaustive.
        0x04: 0,    // KeyA → kVK_ANSI_A
        0x05: 11,   // KeyB → kVK_ANSI_B
        0x06: 8,    // KeyC → kVK_ANSI_C
        0x07: 2,    // KeyD → kVK_ANSI_D
        0x08: 14,   // KeyE → kVK_ANSI_E
        0x09: 3,    // KeyF → kVK_ANSI_F
        0x0A: 5,    // KeyG → kVK_ANSI_G
        0x0B: 4,    // KeyH → kVK_ANSI_H
        0x0C: 34,   // KeyI → kVK_ANSI_I
        0x0D: 38,   // KeyJ → kVK_ANSI_J
        0x0E: 40,   // KeyK → kVK_ANSI_K
        0x0F: 37,   // KeyL → kVK_ANSI_L
        0x10: 46,   // KeyM → kVK_ANSI_M
        0x11: 45,   // KeyN → kVK_ANSI_N
        0x12: 31,   // KeyO → kVK_ANSI_O
        0x13: 35,   // KeyP → kVK_ANSI_P
        0x14: 12,   // KeyQ → kVK_ANSI_Q
        0x15: 15,   // KeyR → kVK_ANSI_R
        0x16: 1,    // KeyS → kVK_ANSI_S
        0x17: 17,   // KeyT → kVK_ANSI_T
        0x18: 32,   // KeyU → kVK_ANSI_U
        0x19: 9,    // KeyV → kVK_ANSI_V
        0x1A: 13,   // KeyW → kVK_ANSI_W
        0x1B: 7,    // KeyX → kVK_ANSI_X
        0x1C: 16,   // KeyY → kVK_ANSI_Y
        0x1D: 6,    // KeyZ → kVK_ANSI_Z

        // Digits — HID 0x1E (Digit1) → kVK_ANSI_1 (18), HID 0x27
        // (Digit0) → kVK_ANSI_0 (29). Note Digit0 is at the END of
        // the HID range, but Carbon orders it consistently.
        0x1E: 18,   // Digit1
        0x1F: 19,   // Digit2
        0x20: 20,   // Digit3
        0x21: 21,   // Digit4
        0x22: 23,   // Digit5
        0x23: 22,   // Digit6
        0x24: 26,   // Digit7
        0x25: 28,   // Digit8
        0x26: 25,   // Digit9
        0x27: 29,   // Digit0

        // Control & whitespace.
        0x28: 36,   // Enter      → kVK_Return
        0x29: 53,   // Escape     → kVK_Escape
        0x2A: 51,   // Backspace  → kVK_Delete
        0x2B: 48,   // Tab        → kVK_Tab
        0x2C: 49,   // Space      → kVK_Space

        // Punctuation row.
        0x2D: 27,   // Minus        → kVK_ANSI_Minus
        0x2E: 24,   // Equal        → kVK_ANSI_Equal
        0x2F: 33,   // BracketLeft  → kVK_ANSI_LeftBracket
        0x30: 30,   // BracketRight → kVK_ANSI_RightBracket
        0x31: 42,   // Backslash    → kVK_ANSI_Backslash
        0x33: 41,   // Semicolon    → kVK_ANSI_Semicolon
        0x34: 39,   // Quote        → kVK_ANSI_Quote
        0x35: 50,   // Backquote    → kVK_ANSI_Grave
        0x36: 43,   // Comma        → kVK_ANSI_Comma
        0x37: 47,   // Period       → kVK_ANSI_Period
        0x38: 44,   // Slash        → kVK_ANSI_Slash

        // Arrows.
        0x4F: 124,  // ArrowRight → kVK_RightArrow
        0x50: 123,  // ArrowLeft  → kVK_LeftArrow
        0x51: 125,  // ArrowDown  → kVK_DownArrow
        0x52: 126,  // ArrowUp    → kVK_UpArrow
    ]
}

extension KeyModifier {
    /// `CGEventFlags` bit for this modifier — kept as a raw
    /// `UInt64` so Domain stays Foundation-only. Values match
    /// Apple's `CGEventFlags.maskShift` etc. in
    /// `<CoreGraphics/CGEventTypes.h>`.
    var cgEventFlag: UInt64 {
        switch self {
        case .shift:   return 0x00020000  // .maskShift
        case .control: return 0x00040000  // .maskControl
        case .option:  return 0x00080000  // .maskAlternate
        case .command: return 0x00100000  // .maskCommand
        }
    }

    /// OR every modifier's `cgEventFlag` into a single mask. The
    /// adapter passes this to `CGEventSetFlags` once per
    /// keystroke instead of cycling modifier-up / modifier-down
    /// events around the key (which races on key handlers that
    /// read `NSEvent.modifierFlags` mid-event).
    static func combinedFlag(of modifiers: Set<KeyModifier>) -> UInt64 {
        modifiers.reduce(0) { $0 | $1.cgEventFlag }
    }
}
