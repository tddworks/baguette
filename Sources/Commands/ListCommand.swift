import BaguetteDevice
import ArgumentParser

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List simulators in the default or a custom device set, then connected physical devices"
    )

    @Option(name: .long, help: "Custom device set path")
    var deviceSet: String?

    @Flag(name: .long, help: "Emit one running/available JSON envelope (matches /simulators.json)")
    var json: Bool = false

    func run() {
        let kinds = DeviceOption.kinds(deviceSet: deviceSet)
        let simulators = kinds.simulators
        if json {
            say(simulators.listJSON)
        } else {
            for sim in simulators.all {
                say(sim.json)
            }
            // Then every device that isn't a simulator — a phone on a
            // cable — in the same line shape.
            for device in kinds.devices.all where device.kind.reality != .simulated {
                say(device.json)
            }
        }
    }
}
