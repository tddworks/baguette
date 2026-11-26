import BaguetteDevice
import Foundation

/// Every kind of device baguette drives, listed once — the only place a kind
/// is named outside its own code. The CLI and `serve` both read it, so a new
/// kind is one line here.
///
/// Companion phones connect only while `serve` runs, so only it passes them.
/// This Mac's displays are reached only when asked for — they show, and
/// drive, the Mac itself.
public struct DeviceKinds: Sendable {
    public let simulators: any Simulators
    public var companions: (any Devices)?
    public var phones: any Devices
    public var androids: any Devices
    public var macs: (any Devices)?

    /// Every family but simulators has a default: phones on a cable through
    /// CoreDevice (`phones: nil`), Android through adb (`androids: nil`), and
    /// neither companion phones nor this Mac's displays unless they are passed.
    public init(
        simulators: any Simulators,
        companions: (any Devices)? = nil,
        phones: (any Devices)? = nil,
        androids: (any Devices)? = nil,
        macs: (any Devices)? = nil
    ) {
        self.simulators = simulators
        self.companions = companions
        self.phones = phones ?? CoreDevicePhones()
        self.androids = androids ?? AndroidDevices()
        self.macs = macs
    }

    /// Simulators, then companion phones, then phones on a cable, then
    /// Android emulators and phones, then this Mac's displays when asked for.
    public var devices: any Devices {
        CombinedDevices([SimulatorDevices(simulators)] + (companions.map { [$0] } ?? []) + [phones, androids] + (macs.map { [$0] } ?? []))
    }
}
