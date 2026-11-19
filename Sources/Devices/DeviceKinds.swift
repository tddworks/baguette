import BaguetteDevice
import Foundation

/// Every kind of device baguette drives, listed once — the only place a kind
/// is named outside its own code. The CLI and `serve` both read it, so a new
/// kind is one line here.
///
/// Companion phones connect only while `serve` runs, so only it passes them.
struct DeviceKinds {
    let simulators: any Simulators
    var companions: (any Devices)? = nil
    var phones: any Devices = CoreDevicePhones()

    /// Simulators, then companion phones, then phones on a cable.
    var devices: any Devices {
        CombinedDevices([SimulatorDevices(simulators)] + (companions.map { [$0] } ?? []) + [phones])
    }
}
