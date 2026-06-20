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

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let ax = simulator.accessibility()

        let result: AXNode?
        switch (x, y) {
        case let (px?, py?):
            result = try ax.describeAt(point: Point(x: px, y: py))
        case (nil, nil):
            result = try ax.describeAll()
        default:
            log("describe-ui: --x and --y must be supplied together")
            throw ExitCode.failure
        }

        guard let tree = result else {
            log("describe-ui: no accessibility data (sim not booted, or no frontmost app)")
            throw ExitCode.failure
        }
        let bytes = Data(tree.json.utf8)
        if let output {
            try bytes.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: bytes)
            try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
        }
    }
}
