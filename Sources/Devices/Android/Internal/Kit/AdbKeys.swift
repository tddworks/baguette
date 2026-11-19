import BaguetteDevice
import Foundation

/// An Android device's buttons and keyboard through `adb shell input`, by
/// Android's own key codes (`AndroidKeyCode`) — which reach every Android
/// device, emulator or phone, with a hardware keyboard or without one (an
/// emulator booted without one drops its control API's key events). A key
/// held down is a long press; a key with modifiers is one key combination.
final class AdbKeys: Press, Key, @unchecked Sendable {
    private let serial: String
    private let adb: Adb

    init(serial: String, adb: Adb) {
        self.serial = serial
        self.adb = adb
    }

    /// The buttons Android has a key code for.
    var available: Set<DeviceButton> { Set(DeviceButton.allCases.filter { AndroidKeyCode.of($0) != nil }) }

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        guard let code = AndroidKeyCode.of(button) else { return false }
        return input(["keyevent"] + (duration > 0 ? ["--longpress"] : []) + ["\(code)"])
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard key.hidUsage.page == 7, let code = AndroidKeyCode.of(usage: key.hidUsage.usage) else { return false }
        guard !modifiers.isEmpty else {
            return input(["keyevent"] + (duration > 0 ? ["--longpress"] : []) + ["\(code)"])
        }
        let held = KeyModifier.allCases.filter(modifiers.contains).map { "\(AndroidKeyCode.of($0))" }
        return input(["keycombination"] + held + ["\(code)"])
    }

    private func input(_ arguments: [String]) -> Bool {
        do {
            _ = try adb.runAndWait(["-s", serial, "shell", "input"] + arguments)
            return true
        } catch {
            log("[android] input \(arguments.joined(separator: " ")) failed: \(error)")
            return false
        }
    }
}
