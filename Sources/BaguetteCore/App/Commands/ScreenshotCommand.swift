import ArgumentParser
import Foundation

/// `baguette screenshot --udid <UDID> [--output path] [--quality N] [--scale N]`
///
/// Captures one JPEG frame from the simulator's framebuffer. Mirrors
/// the `GET /simulators/<UDID>/screenshot.jpg` endpoint so the same
/// helper drives both, and writes to `--output` (or stdout when
/// omitted, so it composes with shell redirection).
struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture one JPEG frame from a simulator's screen"
    )

    @OptionGroup var options: DeviceOption

    @Option(name: .shortAndLong, help: "Output file (defaults to stdout)")
    var output: String?

    @Option(help: "JPEG quality (0.0 – 1.0)")
    var quality: Double = 0.85

    @Option(help: "Integer downscale divisor (1 = native)")
    var scale: Int = 1

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let bytes = try await ScreenSnapshot.capture(
            screen: simulator.screen(),
            quality: quality,
            scale: max(1, scale)
        )
        if let output {
            try bytes.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: bytes)
        }
    }
}
