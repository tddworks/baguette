import Foundation
import IOSurface

/// Stateless JPEG frames: the screen's newest surface, one at a time (`LatestFrame`).
public final class MJPEGStream: Stream, @unchecked Sendable {
    private let configLock = NSLock()
    private var currentConfig: StreamConfig
    public var config: StreamConfig { configLock.withLock { currentConfig } }
    private let sink: any FrameSink
    private let jpeg: JPEGEncoder
    private let scaler = VideoFrameScaler()
    /// Where every frame is encoded; the stream's state is confined to it.
    let queue = DispatchQueue(label: "baguette.mjpeg", qos: .userInteractive)
    private lazy var latest = LatestFrame<IOSurface>(queue: queue, fps: config.fps) { [weak self] surface, ready in
        self?.encode(surface)
        ready()
    }
    private var screen: (any Screen)?
    private var filter = SeedFilter()

    public init(config: StreamConfig, sink: any FrameSink, quality: Double) {
        currentConfig = config
        self.sink = sink
        jpeg = JPEGEncoder(quality: quality)
    }

    public func start(on screen: any Screen) throws {
        log("start: format=mjpeg fps=\(config.fps) scale=\(config.scale)")
        sink.write(MJPEGEnvelope.header)
        self.screen = screen
        queue.sync { filter = SeedFilter() }
        latest.start()
        do { try screen.start { [weak self] in self?.latest.offer($0) } } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        latest.stop()
        screen?.stop()
        screen = nil
    }

    public func update(_ change: StreamConfig.Change) {
        queue.sync {
            let next = change.applied(to: config)
            configLock.withLock { currentConfig = next }
            latest.apply(fps: next.fps)
        }
    }

    public func apply(_ newConfig: StreamConfig) {
        queue.sync {
            configLock.withLock { currentConfig = newConfig }
            latest.apply(fps: newConfig.fps)
        }
    }

    public func requestKeyframe() { /* no-op: MJPEG is stateless */  }
    public func requestSnapshot() { /* no-op: every JPEG is a seed */  }

    /// One paced screen: a JPEG part when it changed. Runs on `queue`.
    func encode(_ surface: IOSurface) {
        guard filter.shouldEmit(surface) else { return }
        guard let pb = scaler.scale(surface, by: config.scale) else { return }
        guard let bytes = jpeg.encode(pb) else { return }
        sink.write(MJPEGEnvelope.framed(jpeg: bytes))
    }
}
