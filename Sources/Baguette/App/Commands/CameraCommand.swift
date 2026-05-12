import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO

/// `baguette camera --udid <UDID> --input <file> [--loop] [--duration N]`
///
/// Injects an image or video into the simulator's camera feed. For
/// images, pushes a single frame (or loops it with `--loop`). For
/// videos (.mp4, .mov), decodes and streams frames at the video's
/// native rate, looping until interrupted or `--duration` expires.
struct CameraCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camera",
        abstract: "Inject image or video into a simulator's camera"
    )

    @OptionGroup var options: DeviceOption

    @Option(name: .shortAndLong, help: "Path to image or video file")
    var input: String

    @Flag(name: .long, help: "Loop the input continuously (images and videos)")
    var loop = false

    @Option(name: .long, help: "Stop after N seconds (0 = indefinite)")
    var duration: Double = 0

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        guard simulator.canAcceptInput else {
            log("Device \(options.udid) is not booted")
            throw ExitCode.failure
        }

        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("File not found: \(input)")
            throw ExitCode.failure
        }

        let camera = simulator.camera()
        let ext = url.pathExtension.lowercased()

        do {
            if ["mp4", "mov", "m4v", "avi"].contains(ext) {
                try camera.injectVideo(url: url)
                log("Streaming video to \(options.udid) — press Ctrl+C to stop")
                await waitForDuration()
            } else {
                guard let image = loadImage(at: url) else {
                    log("Failed to decode image: \(input)")
                    throw ExitCode.failure
                }

                if loop {
                    log("Looping image to \(options.udid) — press Ctrl+C to stop")
                    try camera.injectImage(image)
                    await waitForDuration()
                } else {
                    try camera.injectImage(image)
                    log("Injected image into \(options.udid)")
                }
            }
        } catch {
            log("Camera injection failed: \(error)")
            camera.stop()
            throw ExitCode.failure
        }

        camera.stop()
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func waitForDuration() async {
        if duration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            // Block until SIGINT/SIGTERM — the process exits on signal.
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { Foundation.exit(0) }
            source.resume()
            signal(SIGINT, SIG_IGN)
            try? await Task.sleep(nanoseconds: .max)
        }
    }
}
