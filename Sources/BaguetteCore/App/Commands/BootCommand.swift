import ArgumentParser
import Foundation

struct BootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a simulator headlessly"
    )

    @OptionGroup var options: DeviceOption

    func run() {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        do {
            try simulator.boot()
            log("Booted \(simulator.name)")
        } catch {
            log("Boot failed: \(error)")
            Foundation.exit(1)
        }
    }
}
