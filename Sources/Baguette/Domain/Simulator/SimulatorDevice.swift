import Foundation

/// A simulator, as a `Device`: its identity in the words every family
/// shares, and every role it plays registered as an ability. This is the
/// one place deciding what the simulator family can do.
///
/// An adapter rather than a conformance because `Simulator.state` and
/// `Device.state` are different words for the same fact; it goes away
/// once nothing asks a `Simulator` for a role directly.
struct SimulatorDevice: Device {
    private let simulator: any Simulator

    init(_ simulator: any Simulator) {
        self.simulator = simulator
    }

    var id: DeviceID { DeviceID(simulator.udid) }
    var name: String { simulator.name }
    var state: DeviceState { simulator.state.deviceState }

    var kind: DeviceKind {
        DeviceKind(
            platform: DeviceKind.Platform(runtime: simulator.runtime),
            reality: .simulated,
            model: simulator.deviceTypeName)
    }

    var abilities: AbilityTable {
        let sim = simulator
        var table = AbilityTable(device: sim.name)
        table.register(.lifecycle) { SimulatorLifecycle(simulator: sim) }
        table.register(.screen) { sim.screen() }
        table.register(.input) { sim.input() }
        table.register(.displays) { sim.displays() }
        table.register(.hinge) { sim.hinge() }
        table.register(.externalDisplays) { sim.externalDisplays() }
        table.register(.accessibility) { sim.accessibility() }
        table.register(.logs) { sim.logs() }
        table.register(.orientation) { sim.orientation() }
        table.register(.statusBar) { sim.statusBar() }
        table.register(.interface) { sim.interface() }
        table.register(.location) { sim.location() }
        table.register(.motion) { sim.motion() }
        table.register(.network) { sim.network() }
        table.register(.pasteboard) { sim.pasteboard() }
        table.register(.apps) { sim.apps() }
        table.register(.defaults) { sim.defaults() }
        table.register(.photos) { sim.photos() }
        table.register(.shake) { sim.shake() }
        table.register(.watchPairing) { sim.watchPairing() }
        return table
    }
}

/// The simulator family as a source of `Devices`.
final class SimulatorDevices: Devices {
    private let simulators: any Simulators

    init(_ simulators: any Simulators) {
        self.simulators = simulators
    }

    var all: [any Device] { simulators.all.map(SimulatorDevice.init) }

    func find(id: DeviceID) throws -> (any Device)? {
        simulators.find(udid: id.raw).map(SimulatorDevice.init)
    }
}

private struct SimulatorLifecycle: Lifecycle {
    let simulator: any Simulator
    func boot() throws { try simulator.boot() }
    func shutdown() throws { try simulator.shutdown() }
}

private extension DeviceKind.Platform {
    /// The platform a runtime's display name starts with — "watchOS 12.0".
    /// A runtime the host didn't name reads as iOS, the default device set's.
    init(runtime: String) {
        let word = runtime.split(separator: " ").first.map(String.init) ?? ""
        switch word {
        case "watchOS":           self = .watchOS
        case "tvOS":              self = .tvOS
        case "visionOS", "xrOS":  self = .visionOS
        default:                  self = .iOS
        }
    }
}
