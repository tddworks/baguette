import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface

/// Concrete `Recorder` backed by `AVAssetWriter`. Owns its own
/// `Screen` subscription, accepts every `IOSurface` it sees, and lets
/// AVFoundation handle H.264 encoding + MP4 muxing — VideoToolbox does
/// the actual encoding under the hood, so this is hardware-accelerated
/// and frame-perfect without us touching VT directly.
///
/// Independent of the live stream pipeline. Recording while the live
/// stream is in MJPEG mode just works — both subscribers receive the
/// same surface callbacks; the recorder doesn't care what wire format
/// the browser sees.
///
/// Timestamps are wall-clock relative to the first frame. That keeps
/// playback rate matched to the simulator's real cadence; if the
/// simulator stalls, the recorded video shows the same stall instead
/// of a chipmunk fast-forward, and idle moments aren't padded with
/// duplicate frames.
final class AVAssetWriterRecorder: Recorder, @unchecked Sendable {

    enum RecorderError: Error, CustomStringConvertible, Equatable {
        case alreadyStarted
        case writerSetupFailed(String)
        case noFrames
        case finishFailed(String)

        var description: String {
            switch self {
            case .alreadyStarted:           return "recorder already started"
            case .writerSetupFailed(let m): return "writer setup failed: \(m)"
            case .noFrames:                 return "recorder produced no frames"
            case .finishFailed(let m):      return "finish failed: \(m)"
            }
        }
    }

    let outputURL: URL
    private let bitrate: Int
    private let queue = DispatchQueue(label: "baguette.recorder", qos: .userInteractive)
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var screen: (any Screen)?
    private var sessionStarted = false
    private var firstFrameWallClock: Date?
    private var startedAt: Date?
    private var endedAt: Date?
    /// Append-time pixel buffer pool — AVAssetWriterInputPixelBufferAdaptor
    /// recycles buffers for us, so we don't allocate per frame in the
    /// steady state.
    private var bufferPool: CVPixelBufferPool?

    /// Standard H.264 timescale — fine-grained enough for 60fps
    /// (16.67ms per frame ≈ 10 ticks at 600) without overflowing
    /// CMTime in any practical recording length.
    private let timescale: Int32 = 600

    init(outputURL: URL, bitrate: Int = 8_000_000) {
        self.outputURL = outputURL
        self.bitrate = bitrate
    }

    // MARK: - Recorder

    func start(on screen: any Screen) throws {
        lock.lock()
        guard self.screen == nil else { lock.unlock(); throw RecorderError.alreadyStarted }
        startedAt = Date()
        lock.unlock()

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // AVAssetWriter refuses to overwrite — clear any stale file at
        // the same path before starting. Same path can come up across
        // recordings on the same udid in the same process.
        try? FileManager.default.removeItem(at: outputURL)

        // Configure the screen subscription. Writer setup is deferred
        // to the first surface so we know the frame dimensions; the
        // screen callback hops onto the recorder's queue immediately
        // because AVAssetWriter requires single-queue use.
        try screen.start { [weak self] surface in
            guard let self else { return }
            self.queue.async { self.append(surface: surface) }
        }
        lock.lock()
        self.screen = screen
        lock.unlock()
    }

    func stop() async throws -> RecordingArtifact {
        let snapshot = detachForStop()
        guard let writer = snapshot.writer, let input = snapshot.input, let started = snapshot.startedAt else {
            throw RecorderError.noFrames
        }

        // markAsFinished + finishWriting must be called from the
        // recorder's queue (same queue that's been appending). Block
        // the async task on a continuation until the writer drains.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                input.markAsFinished()
                writer.finishWriting { continuation.resume() }
            }
        }
        endedAt = Date()

        if writer.status == .failed {
            throw RecorderError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw RecorderError.noFrames }

        return RecordingArtifact(
            url: outputURL,
            format: .mp4,
            durationSeconds: (endedAt ?? Date()).timeIntervalSince(started),
            bytes: size
        )
    }

    func cancel() {
        lock.lock()
        let writer = self.writer
        self.screen?.stop()
        self.screen = nil
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        lock.unlock()
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Pull the writer / input / start time out from under the lock,
    /// stop the screen subscription, and clear the slots. Wrapped in
    /// a sync helper so `stop()` can be `async` without holding an
    /// NSLock across an `await` (which Swift's strict concurrency
    /// rightfully refuses).
    private func detachForStop() -> (writer: AVAssetWriter?, input: AVAssetWriterInput?, startedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        let snap = (writer, input, startedAt)
        screen?.stop()
        screen = nil
        return snap
    }

    // MARK: - frame append (recorder queue)

    private func append(surface: IOSurface) {
        // First frame configures the writer with the surface's actual
        // dimensions. Until then we drop frames — this happens for at
        // most a millisecond between start() and the first callback.
        if writer == nil {
            do {
                try configureWriter(
                    width:  IOSurfaceGetWidth(surface),
                    height: IOSurfaceGetHeight(surface)
                )
            } catch {
                log("recorder: writer setup failed: \(error)")
                return
            }
        }
        guard let writer, let input, let adaptor else { return }

        if !sessionStarted {
            // First frame ever — start the session at PTS=0.
            guard writer.startWriting() else {
                log("recorder: startWriting failed: \(writer.error?.localizedDescription ?? "?")")
                return
            }
            writer.startSession(atSourceTime: .zero)
            firstFrameWallClock = Date()
            sessionStarted = true
        }

        // Back-pressure: the writer has a fixed-size queue. Dropping
        // here is rare with `expectsMediaDataInRealTime = true` because
        // VT encodes well under the simulator's emit rate. Better to
        // drop than to block the screen queue.
        guard input.isReadyForMoreMediaData else { return }

        // Wall-clock PTS so the recording plays back at the simulator's
        // real cadence. Tying PTS to a synthetic frame counter would
        // make idle moments compress and busy moments stretch.
        let elapsed = Date().timeIntervalSince(firstFrameWallClock ?? Date())
        let pts = CMTime(seconds: elapsed, preferredTimescale: timescale)

        // Pull a buffer from the adaptor's pool when possible (zero
        // alloc steady-state) and copy the surface into it. Falling
        // back to the IOSurface-wrapped buffer when the pool isn't
        // ready avoids dropping the very first few frames.
        let pixelBuffer: CVPixelBuffer
        if let pooled = makePooledBuffer(from: surface) {
            pixelBuffer = pooled
        } else if let direct = wrap(surface) {
            pixelBuffer = direct
        } else {
            return
        }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    private func configureWriter(width: Int, height: Int) throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecorderError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:        bitrate,
                AVVideoMaxKeyFrameIntervalKey:   60,
                AVVideoProfileLevelKey:          AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey:  false,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttrs
        )
        guard writer.canAdd(input) else {
            throw RecorderError.writerSetupFailed("writer.canAdd(input) returned false")
        }
        writer.add(input)

        self.writer  = writer
        self.input   = input
        self.adaptor = adaptor
        self.bufferPool = adaptor.pixelBufferPool
    }

    // MARK: - pixel buffer helpers

    /// Pull a recycled buffer from the adaptor's pool and copy the
    /// IOSurface contents into it. Returns nil if the pool isn't
    /// ready (very first frames) or the surface dimensions changed
    /// — caller falls back to a direct IOSurface-wrapped buffer.
    private func makePooledBuffer(from surface: IOSurface) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let dst = pb else { return nil }
        guard let src = wrap(surface) else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        let h = CVPixelBufferGetHeight(src)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(src)
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dst)
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let row = min(srcRowBytes, dstRowBytes)
        for y in 0..<h {
            memcpy(dstBase.advanced(by: y * dstRowBytes),
                   srcBase.advanced(by: y * srcRowBytes), row)
        }
        return dst
    }

    private func wrap(_ surface: IOSurface) -> CVPixelBuffer? {
        var pb: Unmanaged<CVPixelBuffer>?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pb
        )
        return status == kCVReturnSuccess ? pb?.takeRetainedValue() : nil
    }
}
