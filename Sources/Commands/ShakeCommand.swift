import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette shake --udid <UDID>`
///
/// Delivers a motion shake to the booted simulator — the same signal as
/// Simulator.app's "Device → Shake". Backed by `simctl spawn <udid>
/// notifyutil -p com.apple.UIKit.SimulatorShake`, which posts the Darwin
/// notification UIKit's shake detection observes into the guest's notify
/// namespace. The value-domain projection lives in
/// `Device/Abilities/Shake/MotionShake.swift`; the spawn is in
/// `Devices/Simulator/Internal/Shake/SimctlShake.swift`.
struct ShakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shake",
        abstract: "Shake the booted simulator (fires UIKit motionShake)"
    )

    @OptionGroup var options: DeviceOption

    func run() async throws {
        let device = try options.device()
        let shake = try orExit { try device.require(.shake) }
        do {
            try await shake.shake()
        } catch {
            log("shake failed: \(error)")
            throw ExitCode.failure
        }
        log("Shook \(device.name)")
    }
}
