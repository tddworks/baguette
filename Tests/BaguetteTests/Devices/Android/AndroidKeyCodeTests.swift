import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Android's own key codes (`KEYCODE_*`, what `adb shell input keyevent`
/// takes) for baguette's buttons and HID keyboard keys.
@Suite("AndroidKeyCode")
struct AndroidKeyCodeTests {
    @Test func `should press Android's navigations and body buttons by their key codes`() {
        #expect(AndroidKeyCode.of(.navigation(.home)) == 3)
        #expect(AndroidKeyCode.of(.navigation(.back)) == 4)
        #expect(AndroidKeyCode.of(.navigation(.appSwitcher)) == 187)
        #expect(AndroidKeyCode.of(.hardware(.power)) == 26)
        #expect(AndroidKeyCode.of(.hardware(.lock)) == 26)
        #expect(AndroidKeyCode.of(.hardware(.volumeUp)) == 24)
        #expect(AndroidKeyCode.of(.hardware(.volumeDown)) == 25)
    }

    @Test func `should have no key code for a button Android doesn't have`() {
        #expect(AndroidKeyCode.of(.hardware(.digitalCrown)) == nil)
        #expect(AndroidKeyCode.of(.navigation(.pullDownToLockScreen)) == nil)
    }

    @Test func `should map a keyboard key's HID usage onto Android's key code`() {
        #expect(AndroidKeyCode.of(usage: 0x04) == 29)    // a
        #expect(AndroidKeyCode.of(usage: 0x1D) == 54)    // z
        #expect(AndroidKeyCode.of(usage: 0x1E) == 8)     // 1
        #expect(AndroidKeyCode.of(usage: 0x27) == 7)     // 0
        #expect(AndroidKeyCode.of(usage: 0x28) == 66)    // return
        #expect(AndroidKeyCode.of(usage: 0x2A) == 67)    // delete
        #expect(AndroidKeyCode.of(usage: 0x2C) == 62)    // space
        #expect(AndroidKeyCode.of(usage: 0x52) == 19)    // up arrow
    }

    @Test func `should map each modifier onto its left key`() {
        #expect(AndroidKeyCode.of(.shift) == 59)
        #expect(AndroidKeyCode.of(.control) == 113)
        #expect(AndroidKeyCode.of(.option) == 57)
        #expect(AndroidKeyCode.of(.command) == 117)
    }
}
