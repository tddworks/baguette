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

    /// Command metadata registered in `RootCommand.subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "camera",
        abstract: "Inject image or video into a simulator's camera"
    )

    /// Simulator identity — `--udid` and optional `--device-set`.
    @OptionGroup var options: DeviceOption

    /// Local path to the image (JPEG, PNG) or video (MP4, MOV) file.
    @Option(name: .shortAndLong, help: "Path to image or video file")
    var input: String

    /// When set, continuously re-inject the input until interrupted.
    @Flag(name: .long, help: "Loop the input continuously (images and videos)")
    var loop = false

    /// Maximum injection duration in seconds. Zero means indefinite
    /// (requires Ctrl+C / SIGINT to stop).
    @Option(name: .long, help: "Stop after N seconds (0 = indefinite)")
    var duration: Double = 0

    /// Entry point — resolves the simulator, loads the media file,
    /// and drives the camera injection pipeline.
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
                await waitForDuration(cleanup: { camera.stop() })
            } else {
                guard let image = loadImage(at: url) else {
                    log("Failed to decode image: \(input)")
                    throw ExitCode.failure
                }

                if loop {
                    log("Looping image to \(options.udid) — press Ctrl+C to stop")
                    try camera.injectImage(image)
                    await waitForDuration(cleanup: { camera.stop() })
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

    /// Decode an image file at `url` into a `CGImage` via ImageIO.
    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Block the current task for `duration` seconds, or indefinitely
    /// if duration is zero. On SIGINT, runs `cleanup` before exiting
    /// so the camera pipeline is torn down cleanly.
    private func waitForDuration(cleanup: @escaping @Sendable () -> Void = {}) async {
        if duration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                cleanup()
                Foundation.exit(0)
            }
            source.resume()
            try? await Task.sleep(nanoseconds: .max)
        }
    }
}
