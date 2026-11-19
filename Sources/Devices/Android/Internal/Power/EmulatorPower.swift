import BaguetteDevice
import Foundation

/// An emulator turned on and off. On: its AVD started headless, as
/// `baguette boot` starts a simulator — no window, no audio — and left
/// running after baguette exits. Off: its console told to stop
/// (`adb emu kill`); an emulator that isn't running stays as it is.
struct EmulatorPower: Power {
    let avd: String
    /// adb's serial while it runs; nil when it is off.
    let serial: String?
    let emulator: URL
    let adb: AndroidTool
    var launch: @Sendable (URL, [String]) throws -> Void = { try DetachedLaunch.run($0, $1) }

    func turnOn() throws {
        try launch(emulator, ["-avd", avd, "-no-window", "-no-audio"])
    }

    func turnOff() throws {
        guard let serial else { return }
        _ = try adb.runAndWait(["-s", serial, "emu", "kill"])
    }
}
