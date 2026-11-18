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
        let simulators = CoreSimulators(deviceSetPath: deviceSet)
        if json {
            print(simulators.listJSON)
        } else {
            for sim in simulators.all {
                print(sim.json)
            }
            // Then every device that isn't a simulator — a phone on a
            // cable — in the same line shape.
            for device in allDevices(deviceSet: deviceSet).all where device.kind.reality != .simulated {
                print(device.json)
            }
        }
    }
}
