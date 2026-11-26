import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

struct ShutdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown",
        abstract: "Shut down a booted simulator"
    )

    @OptionGroup var options: DeviceOption

    func run() throws {
        let device = try options.device()
        let power = try orExit { try device.require(.power) }
        do {
            try power.turnOff()
            tell("Shut down \(device.name)")
        } catch {
            tell("Shutdown failed: \(error)")
            throw ExitCode.failure
        }
    }
}
