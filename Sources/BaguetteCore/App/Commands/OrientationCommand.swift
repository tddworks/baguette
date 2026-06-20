import ArgumentParser
import Foundation

/// `baguette orientation --udid <UDID> <portrait|landscape-left|landscape-right|portrait-upside-down>`
///
/// Sends a `GSEventTypeDeviceOrientationChanged` Purple event to the
/// booted simulator so the iOS guest sees `UIDeviceOrientationDidChange`
/// and rotates the UIKit world. Wire format documented in
/// `Domain/Orientation/OrientationEvent.swift`; the actual mach IPC
/// is in `Infrastructure/Orientation/PurpleEventOrientation.swift`.
struct OrientationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orientation",
        abstract: "Set the booted simulator's interface orientation"
    )

    @OptionGroup var options: DeviceOption

    @Argument(help: "Target orientation: portrait, landscape-left, landscape-right, portrait-upside-down")
    var value: DeviceOrientation

    func run() {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        guard simulator.canAcceptInput else {
            log("Device \(simulator.name) is not booted")
            Foundation.exit(1)
        }
        guard simulator.orientation().set(value) else {
            log("Orientation change rejected (PurpleWorkspacePort unreachable?)")
            Foundation.exit(1)
        }
        log("Set \(simulator.name) → \(value.wireName)")
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
