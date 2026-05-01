import ArgumentParser
import Foundation

struct StreamCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream",
        abstract: "Stream framebuffer to stdout (mjpeg / h264 / avcc). Reads runtime config commands from stdin."
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "Output format: mjpeg | h264 | avcc")
    var format: String = "mjpeg"

    @Option(help: "Frames per second")
    var fps: Int = 60

    @Option(help: "JPEG quality (0.0 – 1.0)")
    var quality: Double = 0.70

    @Option(help: "H.264 average bitrate (bps)")
    var bitrate: Int = StreamConfig.default.bitrateBps

    @Option(help: "Integer downscale divisor (1 = native)")
    var scale: Int = StreamConfig.default.scale

    func run() {
        guard let streamFormat = StreamFormat(rawValue: format) else {
            log("Unknown format: \(format)")
            Foundation.exit(1)
        }
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        let stream = streamFormat.makeStream(
            config: StreamConfig(fps: fps, bitrateBps: bitrate, scale: scale),
            sink: StdoutSink(),
            quality: quality
        )
        do {
            try stream.start(on: simulator.screen())
        } catch {
            log("Stream start failed: \(error)")
            Foundation.exit(1)
        }

        // Listen for runtime control commands on stdin.
        let control = ControlChannel(stream: stream)
        control.start()

        // Clean shutdown on Ctrl+C — GPU processes wind down.
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            control.stop()
            stream.stop()
            Foundation.exit(0)
        }
        src.resume()

        dispatchMain()
    }
}
