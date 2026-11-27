import Foundation
import IOSurface

/// The screen's newest surface, one at a time (`LatestFrame`): the encoder is
/// ready for the next once VideoToolbox answers. Once encoded, every reference
/// frame reaches the sink in order; a still screen is refreshed on a steady
/// beat (`RefreshCadence`), which keeps browser decoder pipelines progressing.
/// A frame VideoToolbox holds past `stallLimit` is given up on, and the
/// next opens a fresh session — for the WebSocket and WebRTC viewers alike
/// (docs/features/stream/design.md).
public final class AVCCStream: Stream, @unchecked Sendable {
    private let configLock = NSLock()
    private var currentConfig: StreamConfig
    public var config: StreamConfig { configLock.withLock { currentConfig } }
    private let sink: any FrameSink
    private let jpeg: JPEGEncoder
    private let encoder: VideoEncoder
    private let scaler = VideoFrameScaler()
    /// Where every frame is encoded, including VideoToolbox's answers; the
    /// stream's state is confined to it.
    let queue = DispatchQueue(label: "baguette.avcc", qos: .userInteractive)
    /// How long VideoToolbox may hold a frame before its session is given
    /// up on: a healthy keyframe takes ~50 ms, so only a wedged one gets here.
    public static let stallLimit: Double = 1.5
    private let stallLimit: Double
    private lazy var latest = LatestFrame<IOSurface>(
        queue: queue, fps: config.fps, stallLimit: stallLimit,
        onStall: { [weak self] in self?.encoderStalled() }
    ) { [weak self] surface, ready in
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

    /// `codec`: what it encodes in — H.264 unless a WebRTC session was answered with another.
    public convenience init(config: StreamConfig, sink: any FrameSink, quality: Double = 0.7, codec: any Codec = H264Codec()) {
        self.init(config: config, sink: sink, quality: quality,
                  encoder: VideoEncoder(fps: config.fps, bitrate: config.bitrateBps, tuning: .strict, codec: codec))
    }

    /// The codec its encoder makes.
    var codec: any Codec { encoder.codec }

    init(config: StreamConfig, sink: any FrameSink, quality: Double, encoder: VideoEncoder,
         stallLimit: Double = AVCCStream.stallLimit) {
        currentConfig = config
        self.sink = sink
        jpeg = JPEGEncoder(quality: quality)
        self.encoder = encoder
        self.stallLimit = stallLimit
    }

    /// On `queue`: VideoToolbox kept a frame past the stall limit. Its
    /// session is let go; the next frame opens a fresh one with a keyframe.
    private func encoderStalled() {
        guard running else { return }
        log("encoder held a frame over \(stallLimit) s; opening a fresh session")
        encoder.abandon()
    }

    public func start(on screen: any Screen) throws {
        log("start: format=avcc codec=\(encoder.codec.recordAtom) fps=\(config.fps) bitrate=\(config.bitrateBps) scale=\(config.scale)")
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
        if old.fps != newConfig.fps { try encoder.setFrameRate(newConfig.fps) }
        if old.bitrateBps != newConfig.bitrateBps { try encoder.setBitrate(newConfig.bitrateBps) }
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
        encoder.stop()
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
        encoder.encode(pb, forceKeyframe: force) { [weak self] result in
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

    private func write(_ encoded: VideoEncoder.Encoded) {
        if let description = encoded.description { sink.write(AVCCEnvelope.description(avcc: description)) }
        switch encoded.kind {
        case .keyframe: sink.write(AVCCEnvelope.keyframe(avcc: encoded.avcc))
        case .delta: sink.write(AVCCEnvelope.delta(avcc: encoded.avcc))
        }
    }
}
