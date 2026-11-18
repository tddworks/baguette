import Foundation
import IOSurface

/// Stateless JPEG frames, paced before encoding with only the latest pending surface.
final class MJPEGStream: Stream, @unchecked Sendable {
    private let configLock = NSLock()
    private var currentConfig: StreamConfig
    var config: StreamConfig { configLock.withLock { currentConfig } }
    private let sink: any FrameSink
    private let jpeg: JPEGEncoder
    private let scaler = VideoFrameScaler()
    private let queue = DispatchQueue(label: "baguette.mjpeg", qos: .userInteractive)
    private lazy var pump = StreamFramePump<IOSurface>(
        queue: queue, fps: config.fps, repeating: false
    ) { [weak self] in self?.encode($0) }
    private var screen: (any Screen)?
    private var filter = SeedFilter()

    init(config: StreamConfig, sink: any FrameSink, quality: Double) {
        currentConfig = config
        self.sink = sink
        jpeg = JPEGEncoder(quality: quality)
    }

    func start(on screen: any Screen) throws {
        log("start: format=mjpeg fps=\(config.fps) scale=\(config.scale)")
        sink.write(MJPEGEnvelope.header)
        self.screen = screen
        queue.sync { filter = SeedFilter() }
        pump.start()
        do { try screen.start { [weak self] in self?.pump.offer($0) } } catch {
            stop()
            throw error
        }
    }

    func stop() {
        pump.stop()
        screen?.stop()
        screen = nil
    }

    func apply(_ newConfig: StreamConfig) {
        queue.sync {
            configLock.withLock { currentConfig = newConfig }
            pump.apply(fps: newConfig.fps)
        }
    }

    func requestKeyframe() { /* no-op: MJPEG is stateless */  }
    func requestSnapshot() { /* no-op: every JPEG is a seed */  }

    private func encode(_ surface: IOSurface) {
        guard filter.shouldEmit(surface) else { return }
        guard let pb = scaler.scale(surface, by: config.scale) else { return }
        guard let bytes = jpeg.encode(pb) else { return }
        sink.write(MJPEGEnvelope.framed(jpeg: bytes))
    }
}
