import Foundation
import IOSurface

/// Pace raw surfaces before encoding. Once encoded, every reference frame reaches
/// the sink in order; the idle repeat keeps browser decoder pipelines progressing.
public final class AVCCStream: Stream, @unchecked Sendable {
    private let configLock = NSLock()
    private var currentConfig: StreamConfig
    public var config: StreamConfig { configLock.withLock { currentConfig } }
    private let sink: any FrameSink
    private let jpeg: JPEGEncoder
    private let h264: H264Encoder
    private let scaler = VideoFrameScaler()
    /// Where every frame is encoded, including VideoToolbox's answers; the
    /// stream's state is confined to it.
    let queue = DispatchQueue(label: "baguette.avcc", qos: .userInteractive)
    private lazy var pump = StreamFramePump<IOSurface>(
        queue: queue, fps: config.fps, repeating: true
    ) { [weak self] in self?.encode($0) }

    private var screen: (any Screen)?
    private var running = false
    private var generation = 0
    private var pendingForceKeyframe = true
    private var pendingSeedSnapshot = true

    public convenience init(config: StreamConfig, sink: any FrameSink, quality: Double = 0.7) {
        self.init(config: config, sink: sink, quality: quality,
                  encoder: H264Encoder(fps: config.fps, bitrate: config.bitrateBps, tuning: .strict))
    }

    init(config: StreamConfig, sink: any FrameSink, quality: Double, encoder: H264Encoder) {
        currentConfig = config
        self.sink = sink
        jpeg = JPEGEncoder(quality: quality)
        h264 = encoder
    }

    public func start(on screen: any Screen) throws {
        log("start: format=avcc fps=\(config.fps) bitrate=\(config.bitrateBps) scale=\(config.scale)")
        self.screen = screen
        queue.sync {
            generation += 1
            running = true
            pendingForceKeyframe = true
            pendingSeedSnapshot = true
        }
        pump.start()
        do { try screen.start { [weak self] in self?.pump.offer($0) } } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        pump.stop()
        screen?.stop()
        screen = nil
        queue.sync { stopEncoding() }
    }

    public func apply(_ newConfig: StreamConfig) throws {
        try queue.sync {
            let old = config
            if old.scale != newConfig.scale {
                generation += 1
                pendingForceKeyframe = true
                pendingSeedSnapshot = true
            }
            if old.fps != newConfig.fps { try h264.setFrameRate(newConfig.fps) }
            if old.bitrateBps != newConfig.bitrateBps { try h264.setBitrate(newConfig.bitrateBps) }
            configLock.withLock { currentConfig = newConfig }
            pump.apply(fps: newConfig.fps)
        }
    }

    public func requestKeyframe() { queue.sync { pendingForceKeyframe = true } }
    public func requestSnapshot() { queue.sync { pendingSeedSnapshot = true } }

    /// Called only on the encode queue, including asynchronous VT completions.
    private func stopEncoding() {
        running = false
        generation += 1
        pump.stop()
        h264.stop()
    }

    /// One paced screen: a seed when one is due, then the frame to the
    /// encoder. Runs on `queue`.
    func encode(_ surface: IOSurface) {
        guard running else { return }
        // A Screen may recycle the IOSurface; VT must retain its own GPU copy.
        guard let pb = scaler.scale(surface, by: config.scale) else { return }
        if pendingSeedSnapshot {
            pendingSeedSnapshot = false
            if let bytes = jpeg.encode(pb) { sink.write(AVCCEnvelope.seed(jpeg: bytes)) }
        }
        let force = pendingForceKeyframe
        pendingForceKeyframe = false
        let submittedGeneration = generation
        h264.encode(pb, forceKeyframe: force) { [weak self] result in
            guard let self else { return }
            queue.async { [self] in
                guard running, generation == submittedGeneration else { return }
                switch result {
                case .success(let encoded?): write(encoded)
                case .success(nil): break
                case .failure(let error):
                    stopEncoding()
                    sink.fail(error)
                }
            }
        }
    }

    private func write(_ encoded: H264Encoder.Encoded) {
        if let description = encoded.description { sink.write(AVCCEnvelope.description(avcc: description)) }
        switch encoded.kind {
        case .keyframe: sink.write(AVCCEnvelope.keyframe(avcc: encoded.avcc))
        case .delta: sink.write(AVCCEnvelope.delta(avcc: encoded.avcc))
        }
    }
}
