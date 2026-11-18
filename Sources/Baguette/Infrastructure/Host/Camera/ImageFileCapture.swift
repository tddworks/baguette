import Foundation

/// `CameraCapture` for a still image. Decodes the file once, then
/// re-emits those pixels under an ever-advancing sequence at a fixed
/// cadence — the dylib's reader only re-renders when the sequence
/// changes and swaps in a "No camera signal" placeholder after ~1 s of
/// staleness, so a still source must keep the buffer "fresh" rather
/// than write once. The decode (`StillImage.load`) is the only
/// integration-only work; the re-emit is driven by `CameraFrame`'s
/// tested `resequenced`.
final class ImageFileCapture: CameraCapture, @unchecked Sendable {
    private let maxDimension: Int
    private let frameInterval: UInt64
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var sequence: UInt32 = 0

    /// - Parameters:
    ///   - maxDimension: canvas cap the decoded image is fitted into.
    ///   - fps: re-emit cadence; must stay above the reader's ~1 Hz
    ///     staleness threshold. ~30 keeps parity with the webcam path.
    init(maxDimension: Int = SharedFrameLayout.maxCanvasWidth, fps: Double = 30) {
        self.maxDimension = maxDimension
        self.frameInterval = UInt64(1_000_000_000 / Swift.max(1.0, fps))
    }

    func start(
        source: CameraSource,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) async throws {
        guard case .image(let path) = source else {
            throw CameraCaptureError.unsupportedSource(source.wireKind)
        }
        let seed = try StillImage.load(path: path, max: maxDimension)
        resetSequence()

        // Emit once immediately so a consumer sees a frame without
        // waiting a full tick, then keep the buffer fresh on a timer.
        emit(seed, to: onFrame)

        let interval = frameInterval
        let pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                self?.emit(seed, to: onFrame)
            }
        }
        swapTask(pump)?.cancel()
    }

    func stop() async {
        swapTask(nil)?.cancel()
    }

    /// Install `pump` as the active timer, returning the one it
    /// replaced (if any) so the caller can cancel it. All `task`
    /// mutation goes through here so the lock never touches an async
    /// context.
    private func swapTask(_ pump: Task<Void, Never>?) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let previous = task
        task = pump
        return previous
    }

    private func emit(_ seed: CameraFrame, to onFrame: @Sendable (CameraFrame) -> Void) {
        lock.lock()
        sequence &+= 1
        let seq = sequence
        lock.unlock()
        onFrame(seed.resequenced(seq))
    }

    private func resetSequence() {
        lock.lock()
        sequence = 0
        lock.unlock()
    }
}
