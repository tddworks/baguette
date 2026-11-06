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
        abstract: "Dump the simulator's accessibility tree as JSON"
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
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let read = try DescribeUI.parse(x: x, y: y, short: short)
        guard let tree = try read.read(from: simulator.accessibility()) else {
            log("describe-ui: no accessibility data (sim not booted, or no frontmost app)")
            throw ExitCode.failure
        }
        let bytes = Data(read.json(of: tree, style: options.affordanceStyle).utf8)
        if let output {
            try bytes.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: bytes)
            try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
        }
    }
}
