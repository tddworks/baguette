import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette describe-ui --udid <UDID> [--x <px> --y <px>]`
///
/// Dumps the simulator's on-screen UI tree as JSON. With `--x` /
/// `--y` it hit-tests a single point (returns the topmost
/// accessibility element under that coordinate); without them it
/// returns the full frontmost-app tree. Frames are in device
/// points, the same units the gesture wire uses.
///
/// Mirrors `idb ui describe-all` / `idb ui describe-point` semantics.
/// `--short` answers with what can be done and what the screen says, without the tree.
struct DescribeUICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Dump a device's accessibility tree as JSON"
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "Hit-test x coordinate (device points). Pair with --y.")
    var x: Double?

    @Option(help: "Hit-test y coordinate (device points). Pair with --x.")
    var y: Double?

    @Option(name: .shortAndLong, help: "Output file (defaults to stdout)")
    var output: String?

    @Flag(help: "Answer with what can be done and what the screen says, without the tree.")
    var short = false

    func validate() throws {
        do {
            _ = try DescribeUI.parse(x: x, y: y, short: short)
        } catch let refusal as DescribeUI.Refusal {
            throw ValidationError(refusal.message)
        }
    }

    func run() async throws {
        // Any device that can do accessibility: a simulator, or a phone on a cable.
        let accessibility = try orExit { try options.devices.require(.accessibility, of: DeviceID(options.udid)) }
        let read = try DescribeUI.parse(x: x, y: y, short: short)
        guard let tree = try read.read(from: accessibility) else {
            tell("describe-ui: no accessibility data (device not ready, or no frontmost app)")
            throw ExitCode.failure
        }
        let json = read.json(of: tree, style: options.affordanceStyle)
        if let output {
            try Data(json.utf8).write(to: URL(fileURLWithPath: output))
        } else {
            say(json)
        }
    }
}
