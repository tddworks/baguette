import ArgumentParser
import Foundation

struct ShutdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown",
        abstract: "Shut down a booted simulator"
    )

    @OptionGroup var options: DeviceOption

    func run() {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        do {
            try simulator.shutdown()
            log("Shut down \(simulator.name)")
        } catch {
            log("Shutdown failed: \(error)")
            Foundation.exit(1)
        }
    }
}
