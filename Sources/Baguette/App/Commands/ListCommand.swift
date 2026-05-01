import ArgumentParser

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List simulators in the default or a custom device set"
    )

    @Option(name: .long, help: "Custom device set path")
    var deviceSet: String?

    func run() {
        let simulators = CoreSimulators(deviceSetPath: deviceSet)
        for sim in simulators.all {
            print(sim.json)
        }
    }
}
