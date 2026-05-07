import ArgumentParser
import Foundation

/// `baguette mac screenshot --bundle-id <X> [--output path] [--quality N] [--scale N]`
///
/// Captures one JPEG of the target macOS app's frontmost window.
/// Mirrors `baguette screenshot`'s flags so calling code can swap
/// `--udid` ↔ `--bundle-id` and otherwise stay identical.
struct MacScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture one JPEG of a macOS app's frontmost window"
    )

    @OptionGroup var target: MacAppOption

    @Option(name: .shortAndLong, help: "Output file (defaults to stdout)")
    var output: String?

    @Option(help: "JPEG quality (0.0 – 1.0)")
    var quality: Double = 0.85

    @Option(help: "Integer downscale divisor (1 = native)")
    var scale: Int = 1

    func run() async throws {
        let apps = RunningMacApps()
        guard let app = apps.find(bundleID: target.bundleId) else {
            log("App \(target.bundleId) not running")
            throw ExitCode.failure
        }
        let bytes = try await ScreenSnapshot.capture(
            screen: app.screen(),
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
