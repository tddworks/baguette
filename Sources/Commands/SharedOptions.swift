import BaguetteDevice
import ArgumentParser

/// Reused by every subcommand that targets one specific simulator.
struct DeviceOption: ParsableArguments {
    @Option(name: .long, help: "Simulator UDID")
    var udid: String

    @Option(name: .long, help: "Custom device set path (defaults to Xcode's default set)")
    var deviceSet: String?

    /// How this run's output offers next steps: as commands that call the
    /// same binary on the same device.
    var affordanceStyle: AXAffordance.Style {
        .commandLine(program: CommandLine.arguments[0], udid: udid, deviceSet: deviceSet)
    }
}

extension DeviceOption {
    /// The device `--udid` names, from every family this host can reach —
    /// or exit 1 saying no source knows it.
    func device() throws -> any Device {
        try orExit { try devices.device(DeviceID(udid)) }
    }

    /// Every device this run can see, from every family.
    var devices: any Devices { allDevices(deviceSet: deviceSet) }
}

/// Every device the CLI can see: the kinds `DeviceKinds` lists, with
/// simulators from `deviceSet` (or Xcode's default set).
func allDevices(deviceSet: String?) -> any Devices {
    DeviceKinds(simulators: CoreSimulators(deviceSetPath: deviceSet)).devices
}

/// Run `body`; a device refusal (`DeviceError`) is logged in its own words
/// and becomes exit 1. Every other error passes through untouched.
func orExit<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let refusal as DeviceError {
        log("\(refusal)")
        throw ExitCode.failure
    }
}

extension DeviceOption {
    /// The device `--udid` names and the role it registered for `ability`,
    /// or exit 1 in the device's own words ("han's iPhone can't do network",
    /// "Device X is not booted").
    func require<Role>(_ ability: Ability<Role>) throws -> (device: any Device, role: Role) {
        let device = try device()
        return (device, try orExit { try device.require(ability) })
    }
}
