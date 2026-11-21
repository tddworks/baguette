import Foundation
import IOSurface

/// The screen's newest surface, one at a time (`LatestFrame`): the encoder is
/// ready for the next once VideoToolbox answers. Once encoded, every reference
/// frame reaches the sink in order; a still screen is refreshed on a steady
/// beat (`RefreshCadence`), which keeps browser decoder pipelines progressing.
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
    private lazy var latest = LatestFrame<IOSurface>(queue: queue, fps: config.fps) { [weak self] surface, ready in
        guard let self else { return ready() }
        encode(surface, ready: ready)
    }
    /// Confined to `queue`.
    private lazy var cadence = RefreshCadence(fps: config.fps)
    private var refreshTimer: DispatchSourceTimer?

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
        latest.start()
        queue.sync { startRefreshing() }
        do { try screen.start { [weak self] in self?.latest.offer($0) } } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        latest.stop()
        screen?.stop()
        screen = nil
        queue.sync { stopEncoding() }
    }

    /// Read and written on the encode queue, so a change made at the same
    /// time from elsewhere lands on top of this one, not under it.
    public func update(_ change: StreamConfig.Change) throws {
        try queue.sync { try retune(to: change.applied(to: config)) }
    }

    public func apply(_ newConfig: StreamConfig) throws {
        try queue.sync { try retune(to: newConfig) }
    }

    /// Runs on `queue`.
    private func retune(to newConfig: StreamConfig) throws {
        let old = config
        if old.scale != newConfig.scale {
            generation += 1
            pendingForceKeyframe = true
            pendingSeedSnapshot = true
        }
        if old.fps != newConfig.fps { try h264.setFrameRate(newConfig.fps) }
        if old.bitrateBps != newConfig.bitrateBps { try h264.setBitrate(newConfig.bitrateBps) }
        configLock.withLock { currentConfig = newConfig }
        latest.apply(fps: newConfig.fps)
        if old.fps != newConfig.fps, refreshTimer != nil {
            cadence.fps = newConfig.fps
            scheduleRefresh()
        }
    }

    public func requestKeyframe() { queue.sync { pendingForceKeyframe = true } }
    public func requestSnapshot() { queue.sync { pendingSeedSnapshot = true } }

    /// Called only on the encode queue, including asynchronous VT completions.
    private func stopEncoding() {
        running = false
        generation += 1
        refreshTimer?.cancel()
        refreshTimer = nil
        latest.stop()
        h264.stop()
    }

    /// The refresh beat, on `queue`: each refresh is taken only when the
    /// encoder has nothing else (`LatestFrame.refresh`).
    private func startRefreshing() {
        refreshTimer?.cancel()
        cadence = RefreshCadence(fps: config.fps)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, running else { return }
            latest.refresh()
            scheduleRefresh()
        }
        refreshTimer = timer
        scheduleRefresh()
        timer.resume()
    }

    private func scheduleRefresh() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let due = cadence.next(at: now)
        refreshTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: UInt64(due * 1_000_000_000)), leeway: .microseconds(250))
    }

    /// One screen: a seed when one is due, then the frame to the encoder.
    /// `ready` once VideoToolbox has answered — or at once when the frame
    /// isn't encoded at all, or the stream would wait on it for good.
    /// Runs on `queue`.
    func encode(_ surface: IOSurface, ready: @escaping @Sendable () -> Void) {
        guard running else { return ready() }
        // A Screen may recycle the IOSurface; VT must retain its own GPU copy.
        guard let pb = scaler.scale(surface, by: config.scale) else { return ready() }
        if pendingSeedSnapshot {
            pendingSeedSnapshot = false
            if let bytes = jpeg.encode(pb) { sink.write(AVCCEnvelope.seed(jpeg: bytes)) }
        }
        let force = pendingForceKeyframe
        pendingForceKeyframe = false
        let submittedGeneration = generation
        h264.encode(pb, forceKeyframe: force) { [weak self] result in
            guard let self else { return ready() }
            queue.async { [self] in
                defer { ready() }
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
