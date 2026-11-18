import ArgumentParser
import Foundation

/// `baguette orientation --udid <UDID> <portrait|landscape-left|landscape-right|portrait-upside-down>`
///
/// Foldables use the guest pose helper; ordinary devices use PurpleWorkspace.
/// Apps can keep their own interface orientation after successful dispatch.
struct OrientationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orientation",
        abstract: "Set the booted simulator's orientation"
    )

    @OptionGroup var options: DeviceOption

    @Argument(help: "Target orientation: portrait, landscape-left, landscape-right, portrait-upside-down")
    var value: DeviceOrientation

    func run() throws {
        let device = try options.device()
        let orientation = try orExit { try device.require(.orientation) }
        let delivery = orientation.set(value)
        switch delivery {
        case .delivered:
            log("Set \(device.name) → \(value.wireName)")
        case .rejected:
            log("Orientation change rejected (event port or guest pose helper unavailable?)")
        case .unconfirmed:
            log("Orientation change unconfirmed; read the device state before retrying")
        }
        if delivery != .delivered { Foundation.exit(delivery.exitStatus) }
    }
}

/// ArgumentParser conformance lives in App so Domain stays free of
/// ArgumentParser. The actual kebab-case parsing is in
/// `DeviceOrientation(wireName:)` (Domain) — `init(argument:)`
/// just delegates so the CLI and HTTP route share one mapping.
extension DeviceOrientation: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(wireName: argument)
    }

    /// Without this, ArgumentParser derives `allValueStrings` from
    /// the `UInt32` raw values and prints `(values: 1, 2, 3, 4)`.
    public static var allValueStrings: [String] {
        ["portrait", "landscape-left", "landscape-right", "portrait-upside-down"]
    }
}
