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
    /// Optional recorder that taps the encoder output. Nil unless the
    /// caller has invoked `attach(recorder:)`. Holds a reference rather
    /// than owning the lifecycle — Server creates / finishes the
    /// recorder around the WS verbs so the stream stays oblivious to
    /// where the bytes land.
    ///
    /// Read from VT's onEncoded callback (a different queue), so guard
    /// every access with `recorderLock`. Without the lock, the very
    /// first description / IDR right after attach() can land on the WS
    /// thread before `self.recorder = recorder` is visible — which is
    /// exactly the frame the recorder needs to spawn ffmpeg.
    private var recorder: (any H264Recorder)?
    private let recorderLock = NSLock()
    /// Most recent avcC parameter-set blob seen on this encoder session.
    /// `H264Encoder` emits a description exactly once per session (on
    /// the very first IDR), so by the time a recorder attaches mid-
    /// stream the description is long gone. Caching it lets us replay
    /// it on attach so the recorder's AnnexBAssembler can prime its
    /// SPS/PPS preamble; without it, no keyframe ever makes it past
    /// the assembler and ffmpeg never spawns.
    private var cachedDescription: Data?

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

    /// Subscribe a recorder to the encoder's output. Forces the next
    /// frame to be an IDR so the recording starts on a clean seek
    /// point, and replays the cached avcC description so the recorder
    /// has SPS/PPS before the keyframe arrives. `H264Encoder` only
    /// emits description once per session, so without the replay the
    /// recorder never primes its AnnexBAssembler and ffmpeg never
    /// spawns. Synchronous — the recorder must be visible to VT's
    /// encoder callback before the next frame fires.
    func attach(recorder: any H264Recorder) {
        recorderLock.lock()
        self.recorder = recorder
        let cached = cachedDescription
        recorderLock.unlock()
        if let cached { recorder.write(description: cached) }
        queue.async { [weak self] in self?.pendingForceKeyframe = true }
    }

    /// Detach the recorder. Caller is responsible for finishing /
    /// cancelling it — this only stops the tee.
    func detachRecorder() {
        recorderLock.lock()
        self.recorder = nil
        recorderLock.unlock()
    }

    /// Snapshot the current recorder under the lock — VT's encoder
    /// queue calls this once per encoded frame, so we keep the lock
    /// hold trivial and do the actual `write()` calls outside it.
    private func currentRecorder() -> (any H264Recorder)? {
        recorderLock.lock(); defer { recorderLock.unlock() }
        return recorder
    }

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
            recorderLock.lock()
            cachedDescription = description
            recorderLock.unlock()
            sink.write(AVCCEnvelope.description(avcc: description))
        }
        let activeRecorder = currentRecorder()
        if let description = encoded.description {
            activeRecorder?.write(description: description)
        }
        switch encoded.kind {
        case .keyframe:
            sink.write(AVCCEnvelope.keyframe(avcc: encoded.avcc))
            activeRecorder?.write(keyframe: encoded.avcc)
        case .delta:
            sink.write(AVCCEnvelope.delta(avcc: encoded.avcc))
            activeRecorder?.write(delta: encoded.avcc)
        }
    }
}

/// Marker protocol the Server uses to discover whether a `Stream` impl
/// can host a recorder. AVCCStream conforms; MJPEGStream doesn't,
/// because re-muxing MJPEG into MP4 would mean a full re-encode and
/// defeats the whole "tap the existing H.264 NALs" premise.
protocol RecordableStream: AnyObject {
    func attach(recorder: any H264Recorder)
    func detachRecorder()
}

extension AVCCStream: RecordableStream {}
