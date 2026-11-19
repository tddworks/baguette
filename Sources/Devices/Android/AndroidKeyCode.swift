import BaguetteDevice
import Foundation

/// Android's own key codes (`KEYCODE_*` in `android.view.KeyEvent`) — what
/// `adb shell input keyevent` takes — for baguette's buttons, keyboard keys
/// (by HID usage, page 7) and modifiers. Nil for what Android has no key for.
enum AndroidKeyCode {
    static func of(_ button: DeviceButton) -> Int? {
        switch button {
        case .navigation(.home): 3
        case .navigation(.back): 4
        case .navigation(.appSwitcher): 187
        case .hardware(.power), .hardware(.lock): 26
        case .hardware(.volumeUp): 24
        case .hardware(.volumeDown): 25
        default: nil
        }
    }

    static func of(usage: UInt32) -> Int? {
        switch usage {
        case 0x04...0x1D: Int(usage - 0x04) + 29                    // a–z
        case 0x1E...0x26: Int(usage - 0x1E) + 8                     // 1–9
        case 0x27: 7                                                // 0
        default: Self.named[usage]
        }
    }

    static func of(_ modifier: KeyModifier) -> Int {
        switch modifier {
        case .shift: 59
        case .control: 113
        case .option: 57
        case .command: 117
        }
    }

    private static let named: [UInt32: Int] = [
        0x28: 66, 0x29: 111, 0x2A: 67, 0x2B: 61, 0x2C: 62,          // return, escape, delete, tab, space
        0x2D: 69, 0x2E: 70, 0x2F: 71, 0x30: 72, 0x31: 73,           // - = [ ] \
        0x33: 74, 0x34: 75, 0x35: 68, 0x36: 55, 0x37: 56, 0x38: 76, // ; ' ` , . /
        0x4C: 112,                                                  // forward delete
        0x4F: 22, 0x50: 21, 0x51: 20, 0x52: 19,                     // → ← ↓ ↑
    ]
}
