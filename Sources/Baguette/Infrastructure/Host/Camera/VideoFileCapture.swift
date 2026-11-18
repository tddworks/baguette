import Foundation

/// `CameraCapture` for a looping video file. Pulls decoded frames off a
/// `VideoDecoder`, paces them by their presentation timestamps, assigns
/// a monotonic per-session sequence, and — when the asset is exhausted
/// — rewinds and keeps going, so the sim sees an endless feed. All the
/// AVFoundation decode work lives behind the injected `VideoDecoder`;
/// this orchestrator is unit-covered via `MockVideoDecoder`.
final class VideoFileCapture: CameraCapture, @unchecked Sendable {
    private let decoder: any VideoDecoder
    private let maxDimension: Int
    private let maxPacingGapMs: UInt32
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var sequence: UInt32 = 0

    /// - Parameters:
    ///   - maxDimension: canvas cap each decoded frame is fitted into.
    ///   - maxPacingGapMs: ceiling on the wait between two frames. A
    ///     corrupt asset can report neighbouring timestamps days apart;
    ///     honoured literally that parks the pump and the feed goes
    ///     dead. The sim's reader calls the shared buffer stale after
    ///     ~1 s regardless, so there's nothing to gain past that.
    init(
        decoder: any VideoDecoder,
        maxDimension: Int = SharedFrameLayout.maxCanvasWidth,
        maxPacingGapMs: UInt32 = 1000
    ) {
        self.decoder = decoder
        self.maxDimension = maxDimension
        self.maxPacingGapMs = maxPacingGapMs
    }

    convenience init() {
        self.init(decoder: AVVideoDecoder())
    }

    func start(
        source: CameraSource,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) async throws {
        guard case .video(let path) = source else {
            throw CameraCaptureError.unsupportedSource(source.wireKind)
        }
        try await decoder.start(path: path, maxDimension: maxDimension)
        resetSequence()
        let pump = Task { [weak self] in
            guard let self else { return }
            await self.pump(onFrame)
        }
        swapTask(pump)?.cancel()
    }

    func stop() async {
        swapTask(nil)?.cancel()
        decoder.stop()
    }

    /// Decode → pace → emit, looping at end of asset. Breaks on a decode
    /// error or a genuinely empty asset (two EOFs with no frame between
    /// them) so a bad file can't spin a busy loop.
    private func pump(_ onFrame: @Sendable (CameraFrame) -> Void) async {
        var lastPresentationMs: UInt32?
        var emptyStreak = 0
        while !Task.isCancelled {
            let decoded: DecodedVideoFrame?
            do { decoded = try decoder.nextFrame() } catch { break }

            guard let frame = decoded else {
                // A cancel racing EOF must not pay for a rewind — that
                // re-opens the asset and reloads its track metadata.
                if Task.isCancelled { break }
                emptyStreak += 1
                if emptyStreak >= 2 { break }  // rewound and still nothing
                do { try await decoder.rewind() } catch { break }
                lastPresentationMs = nil
                continue
            }
            emptyStreak = 0

            // Pace to the gap since the previous frame; a rewind resets
            // the clock (lastPresentationMs == nil → emit immediately).
            if let last = lastPresentationMs, frame.presentationMs > last {
                let gapMs = Swift.min(frame.presentationMs - last, maxPacingGapMs)
                try? await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000)
            }
            // The sleep above reports cancellation by throwing, and `try?`
            // swallows it — so re-check, or a stopped pump emits one last
            // frame into a buffer nobody is streaming any more.
            if Task.isCancelled { break }
            lastPresentationMs = frame.presentationMs

            let seq = nextSequence()
            if let cameraFrame = try? frame.frame(sequence: seq) {
                onFrame(cameraFrame)
            }
        }
    }

    private func nextSequence() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    private func resetSequence() {
        lock.lock()
        defer { lock.unlock() }
        sequence = 0
    }

    private func swapTask(_ pump: Task<Void, Never>?) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let previous = task
        task = pump
        return previous
    }
}
