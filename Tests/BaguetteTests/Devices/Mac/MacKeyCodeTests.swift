import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac's own virtual key codes (`kVK_*` in Carbon's Events.h) for
/// baguette's keyboard keys (HID page 7) and modifiers.
@Suite("MacKeyCode")
struct MacKeyCodeTests {
    @Test func `should map a letter key onto the Mac's ANSI key code`() {
        #expect(MacKeyCode.of(usage: 0x04) == 0x00)   // a
        #expect(MacKeyCode.of(usage: 0x05) == 0x0B)   // b
        #expect(MacKeyCode.of(usage: 0x1D) == 0x06)   // z
    }

    @Test func `should map the top row's digits, zero last`() {
        #expect(MacKeyCode.of(usage: 0x1E) == 0x12)   // 1
        #expect(MacKeyCode.of(usage: 0x22) == 0x17)   // 5
        #expect(MacKeyCode.of(usage: 0x27) == 0x1D)   // 0
    }

    @Test func `should map return, the arrows and the keypad`() {
        #expect(MacKeyCode.of(usage: 0x28) == 0x24)   // return
        #expect(MacKeyCode.of(usage: 0x2A) == 0x33)   // delete
        #expect(MacKeyCode.of(usage: 0x50) == 0x7B)   // left arrow
        #expect(MacKeyCode.of(usage: 0x62) == 0x52)   // keypad 0
        #expect(MacKeyCode.of(usage: 0x58) == 0x4C)   // keypad enter
    }

    @Test func `should map no code when the Mac has no such key`() {
        #expect(MacKeyCode.of(usage: 0xE8) == nil)
    }

    @Test func `should map each modifier onto its left-hand key`() {
        #expect(MacKeyCode.of(.command) == 0x37)
        #expect(MacKeyCode.of(.shift) == 0x38)
        #expect(MacKeyCode.of(.option) == 0x3A)
        #expect(MacKeyCode.of(.control) == 0x3B)
    }
}
