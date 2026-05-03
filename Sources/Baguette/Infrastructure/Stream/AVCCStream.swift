import Foundation
import IOSurface

/// AVCC stream: H.264 NALs (length-prefixed AVCC chunks) preceded by a
/// one-shot JPEG seed (tag 0x04) so consumers paint instantly on the
/// first frame — VideoDecoder warm-up + first IDR can otherwise leave a
/// blank canvas.
///
/// Driven by `screen` callbacks like MJPEG: every time SimulatorKit
/// composites a frame, we encode it. This preserves the simulator's
/// real cadence — pinch / scroll / animation stay smooth because no
/// fixed-rate sampler decimates the stream.
final class AVCCStream: Stream, @unchecked Sendable {
    private(set) var config: StreamConfig
    private let sink: any FrameSink
    private let jpeg: JPEGEncoder
    private let h264: H264Encoder
    private let scaler = Scaler()
    private let queue = DispatchQueue(label: "baguette.avcc", qos: .userInteractive)

    private var screen: (any Screen)?
    private var lastSurface: IOSurface?
    private var pump: DispatchSourceTimer?
    private var pendingForceKeyframe = true
    /// Pre-armed at start so the first surface emits a JPEG seed; later
    /// flips back on via `requestSnapshot()`.
    private var pendingSeedSnapshot = true

    init(config: StreamConfig, sink: any FrameSink, quality: Double = 0.7) {
        self.config = config
        self.sink = sink
        self.jpeg = JPEGEncoder(quality: quality)
        self.h264 = H264Encoder(fps: config.fps, bitrate: config.bitrateBps)
        self.h264.onEncoded = { [weak self] in self?.write($0) }
    }

    func start(on screen: any Screen) throws {
        log("start: format=avcc fps=\(config.fps) bitrate=\(config.bitrateBps) scale=\(config.scale)")
        self.screen = screen
        try screen.start { [weak self] surface in
            self?.handle(surface)
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        screen?.stop()
        screen = nil
        lastSurface = nil
    }

    func apply(_ newConfig: StreamConfig) {
        let old = config
        config = newConfig
        log("apply: fps \(old.fps)→\(newConfig.fps), bitrate \(old.bitrateBps)→\(newConfig.bitrateBps), scale \(old.scale)→\(newConfig.scale)")
        if old.bitrateBps != newConfig.bitrateBps {
            h264.setBitrate(newConfig.bitrateBps)
        }
    }

    /// Re-arms the idle pump to fire `1/fps` from now. Called after every
    /// encode — if screen callbacks keep flowing, the timer keeps getting
    /// pushed back and never fires; only a real idle (no callback for
    /// 1/fps) lets it tick.
    private func armPump() {
        pump?.cancel()
        let interval = 1.0 / Double(max(1, config.fps))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pumpTick() }
        timer.resume()
        pump = timer
    }

    private func pumpTick() {
        // Already on queue. Re-encode the last surface so the decoder
        // pipeline keeps flowing — without this, an idle simulator leaves
        // the last delta stuck in the consumer's `VideoDecoder` queue and
        // the canvas freezes on a stale frame.
        guard let surface = lastSurface else { return }
        encode(surface)
    }

    func requestKeyframe() { pendingForceKeyframe = true }
    func requestSnapshot() { pendingSeedSnapshot = true }

    private func handle(_ surface: IOSurface) {
        queue.async { [weak self] in
            self?.lastSurface = surface
            self?.encode(surface)
            self?.armPump()
        }
    }

    private func encode(_ surface: IOSurface) {
        // Always copy via Scaler before handing to VT: VT encodes async on
        // its own thread and SimulatorKit recycles the framebuffer
        // IOSurface in place — the bare ref races. At scale=1 the scaler
        // produces a 1:1 GPU copy, the stable buffer VT needs.
        guard let pb = scaler.downscale(surface, scale: config.scale) else { return }
        if pendingSeedSnapshot {
            pendingSeedSnapshot = false
            if let bytes = jpeg.encode(pb) {
                sink.write(AVCCEnvelope.seed(jpeg: bytes))
            }
        }
        let force = pendingForceKeyframe
        pendingForceKeyframe = false
        h264.encode(pb, forceKeyframe: force)
    }

    private func write(_ encoded: H264Encoder.Encoded) {
        if let description = encoded.description {
            sink.write(AVCCEnvelope.description(avcc: description))
        }
        switch encoded.kind {
        case .keyframe: sink.write(AVCCEnvelope.keyframe(avcc: encoded.avcc))
        case .delta:    sink.write(AVCCEnvelope.delta(avcc: encoded.avcc))
        }
    }
}
