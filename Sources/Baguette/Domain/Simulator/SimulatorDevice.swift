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

    var abilities: Abilities {
        let sim = simulator
        var abilities = Abilities(device: sim.name)
        abilities.register(.power) { SimulatorPower(simulator: sim) }
        abilities.register(.screen) { sim.screen() }
        // One HID for the four input roles: a keystroke has to ride the
        // Indigo services a gesture warmed, never a second client of its own.
        let hid = OneHID { sim.input() }
        abilities.register(.touch) { hid.surface }
        abilities.register(.press) { hid.surface }
        abilities.register(.key) { hid.surface }
        abilities.register(.scroll) { hid.surface }
        abilities.register(.displays) { sim.displays() }
        abilities.register(.hinge) { sim.hinge() }
        abilities.register(.externalDisplays) { sim.externalDisplays() }
        abilities.register(.accessibility) { sim.accessibility() }
        abilities.register(.logs) { sim.logs() }
        abilities.register(.orientation) { sim.orientation() }
        abilities.register(.statusBar) { sim.statusBar() }
        abilities.register(.interface) { sim.interface() }
        abilities.register(.location) { sim.location() }
        abilities.register(.motion) { sim.motion() }
        abilities.register(.network) { sim.network() }
        abilities.register(.inputSurface) { sim.inputSurface() }
        abilities.register(.camera) { sim.camera() }
        abilities.register(.pasteboard) { sim.pasteboard() }
        abilities.register(.apps) { sim.apps() }
        abilities.register(.notify) { sim.notify() }
        abilities.register(.defaults) { sim.defaults() }
        abilities.register(.photos) { sim.photos() }
        abilities.register(.shake) { sim.shake() }
        abilities.register(.watchPairing) { sim.watchPairing() }
        return abilities
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

/// The HID a simulator's abilities share, made the first time a role asks.
private final class OneHID: @unchecked Sendable {
    private let make: @Sendable () -> any HID
    private let lock = NSLock()
    private var made: (any HID)?

    init(_ make: @escaping @Sendable () -> any HID) {
        self.make = make
    }

    var surface: any HID {
        lock.lock()
        defer { lock.unlock() }
        if let made { return made }
        let surface = make()
        made = surface
        return surface
    }
}

private struct SimulatorPower: Power {
    let simulator: any Simulator
    func turnOn() throws { try simulator.boot() }
    func turnOff() throws { try simulator.shutdown() }
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
