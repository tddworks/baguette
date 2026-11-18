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
        let lifecycle = try orExit { try device.require(.lifecycle) }
        do {
            try lifecycle.shutdown()
            log("Shut down \(device.name)")
        } catch {
            log("Shutdown failed: \(error)")
            Foundation.exit(1)
        }
    }
}
