import ArgumentParser
import Foundation

struct StreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream",
        abstract: "Stream framebuffer to stdout (mjpeg / avcc). Reads runtime config commands from stdin."
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "Output format: \(StreamFormat.allCases.map(\.rawValue).joined(separator: " | "))")
    var format: String = "mjpeg"

    @Option(help: "Frames per second")
    var fps: Int = 60

    @Option(help: "JPEG quality (0.0 – 1.0)")
    var quality: Double = 0.70

    @Option(help: "H.264 average bitrate (bps)")
    var bitrate: Int = StreamConfig.default.bitrateBps

    @Option(help: "Integer downscale divisor (1 = native)")
    var scale: Int = StreamConfig.default.scale

    func run() async throws {
        guard let streamFormat = StreamFormat(rawValue: format) else {
            log("Unknown format: \(format)")
            throw ExitCode.failure
        }
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let termination = AsyncThrowingStream<Void, any Error>.makeStream()
        let onFailure: @Sendable (any Error) -> Void = { error in
            termination.continuation.finish(throwing: error)
        }
        let stream = streamFormat.makeStream(
            config: StreamConfig(fps: fps, bitrateBps: bitrate, scale: scale),
            sink: StdoutSink(onFailure: onFailure),
            quality: quality
        )
        // AsyncParsableCommand runs on the cooperative executor;
        // dispatchMain() requires the process's main thread.
        let sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { termination.continuation.finish() }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        try await Self.capture(stream, on: simulator.screen(), onFailure: onFailure) {
            for try await _ in termination.stream {}
        }
    }

    static func capture(
        _ stream: any Stream,
        on screen: any Screen,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        until stopped: () async throws -> Void
    ) async throws {
        // start() can install some callbacks before reporting a failure.
        defer { stream.stop() }
        try stream.start(on: screen)
        let control = ControlChannel(stream: stream, onFailure: onFailure)
        control.start()
        defer { control.stop() }
        try await stopped()
    }
}
