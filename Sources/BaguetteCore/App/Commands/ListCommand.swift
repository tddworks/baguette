import ArgumentParser

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List simulators in the default or a custom device set"
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
        }
    }
}
