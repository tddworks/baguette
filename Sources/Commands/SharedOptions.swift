import BaguetteDevice
import BaguetteCoreDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

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
    /// The kinds of device a run reaches, when something other than this
    /// host decided them: a test hands a command its devices here. Unset —
    /// every real run — a run reaches every family `DeviceKinds` lists.
    @TaskLocal static var reachable: DeviceKinds?

    /// The kinds of device this run reaches, simulators from `deviceSet`
    /// (or Xcode's default set).
    static func kinds(deviceSet: String?) -> DeviceKinds {
        reachable ?? DeviceKinds(simulators: CoreSimulators(deviceSetPath: deviceSet), coreDevice: .live)
    }

    /// The device `--udid` names, from every family this host can reach —
    /// or exit 1 saying no source knows it.
    /// A Mac display's UUID given here is itself the ask to reach it.
    func device() throws -> any Device {
        var kinds = Self.kinds(deviceSet: deviceSet)
        if Self.reachable == nil { kinds.macs = MacDisplays.onThisMac() }
        return try orExit { try kinds.devices.device(DeviceID(udid)) }
    }

    /// Every device this run can see, from every family.
    var devices: any Devices { allDevices(deviceSet: deviceSet) }
}

/// Every device the CLI can see: the kinds `DeviceKinds` lists, with
/// simulators from `deviceSet` (or Xcode's default set).
func allDevices(deviceSet: String?) -> any Devices {
    DeviceOption.kinds(deviceSet: deviceSet).devices
}

/// Run `body`; a device refusal (`DeviceError`) is told in its own words
/// and becomes exit 1. Every other error passes through untouched.
func orExit<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let refusal as DeviceError {
        tell("\(refusal)")
        throw ExitCode.failure
    }
}

/// Where a command's words go: what it answers (stdout), what it tells
/// the user along the way (stderr), and what it answers as raw bytes (an
/// image, text piped byte-faithfully). Injected so a command's body can be
/// run, and read back, in a test.
struct CommandOutput: Sendable {
    let say: @Sendable (String) -> Void
    let warn: @Sendable (String) -> Void
    let write: @Sendable (Data) -> Void

    init(
        say: @escaping @Sendable (String) -> Void,
        warn: @escaping @Sendable (String) -> Void,
        write: @escaping @Sendable (Data) -> Void = { FileHandle.standardOutput.write($0) }
    ) {
        self.say = say
        self.warn = warn
        self.write = write
    }

    /// stdout and stderr, as every command writes them.
    static let standard = CommandOutput(say: { print($0) }, warn: { log($0) })

    /// Where this run's words go: stdout and stderr, unless a test is
    /// reading them back.
    @TaskLocal static var current: CommandOutput = .standard
}

/// Answer `line` on this run's stdout.
func say(_ line: String) { CommandOutput.current.say(line) }

/// Tell the user `line` on this run's stderr.
func tell(_ line: String) { CommandOutput.current.warn(line) }

extension DeviceOption {
    /// The device `--udid` names and the role it registered for `ability`,
    /// or exit 1 in the device's own words ("han's iPhone can't do network",
    /// "Device X is not booted").
    func require<Role>(_ ability: Ability<Role>) throws -> (device: any Device, role: Role) {
        let device = try device()
        return (device, try orExit { try device.require(ability) })
    }
}
