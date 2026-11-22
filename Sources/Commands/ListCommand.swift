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

    @Flag(name: .long, help: "Also list this Mac's displays, which `stream`, `record` and `serve --share-mac` can show and drive")
    var mac: Bool = false

    func run() {
        var kinds = DeviceOption.kinds(deviceSet: deviceSet)
        if mac, DeviceOption.reachable == nil { kinds.macs = MacDisplays.onThisMac() }
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
