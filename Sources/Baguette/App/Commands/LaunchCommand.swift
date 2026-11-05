import ArgumentParser
import Foundation

/// `baguette launch --udid <UDID> --bundle-id <ID> [--relaunch] [--describe-ui]`
///
/// Opens an installed app. `--describe-ui` waits for its first real screen and
/// answers with it, replacing a guessed sleep and the empty reads a launching
/// app gives.
struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed app, optionally answering with its first screen"
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "Bundle id of an installed app")
    var bundleId: String

    @Flag(help: "Quit the app first, so it starts fresh.")
    var relaunch = false

    @Flag(help: "Wait for the app's first screen, then answer with whether the screen changed and its accessibility tree.")
    var describeUI = false

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let result = await AppLaunch.perform(
            bundleID: bundleId, relaunch: relaunch, describeUI: describeUI,
            apps: simulator.apps(), accessibility: simulator.accessibility())
        print(result)
        if !result.hasPrefix(#"{"ok":true"#) { throw ExitCode.failure }
    }
}
