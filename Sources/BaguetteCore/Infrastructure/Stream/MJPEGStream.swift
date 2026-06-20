import Foundation
import IOSurface

/// MJPEG stream: stateless JPEG-per-frame inside a multipart HTTP envelope.
///
/// Mirrors `AVCCStream` shape — same `handle` / `encode` flow, same
/// scaler-backed copy. Only the encoder differs.
final class MJPEGStream: Stream, @unchecked Sendable {
    private(set) var config: StreamConfig
    private let sink: any FrameSink
    private let jpeg: JPEGEncoder
    private let scaler = Scaler()
    private let queue = DispatchQueue(label: "baguette.mjpeg", qos: .userInteractive)

    private var screen: (any Screen)?
    private var filter = SeedFilter()

    init(config: StreamConfig, sink: any FrameSink, quality: Double) {
        self.config = config
        self.sink = sink
        self.jpeg = JPEGEncoder(quality: quality)
    }

    func start(on screen: any Screen) throws {
        log("start: format=mjpeg fps=\(config.fps) scale=\(config.scale)")
        sink.write(MJPEGEnvelope.header)
        self.screen = screen
        try screen.start { [weak self] surface in
            self?.handle(surface)
        }
    }

    func stop() {
        screen?.stop()
        screen = nil
    }

    func apply(_ newConfig: StreamConfig) {
        let old = config
        config = newConfig
        log("apply: fps \(old.fps)→\(newConfig.fps), scale \(old.scale)→\(newConfig.scale)")
    }

    func requestKeyframe() { /* no-op: MJPEG is stateless */ }
    func requestSnapshot() { /* no-op: every JPEG is a seed */ }

    private func handle(_ surface: IOSurface) {
        guard filter.shouldEmit(surface) else { return }
        queue.async { [weak self] in self?.encode(surface) }
    }

    private func encode(_ surface: IOSurface) {
        guard let pb = scaler.downscale(surface, scale: config.scale) else { return }
        guard let bytes = jpeg.encode(pb) else { return }
        sink.write(MJPEGEnvelope.framed(jpeg: bytes))
    }
}
