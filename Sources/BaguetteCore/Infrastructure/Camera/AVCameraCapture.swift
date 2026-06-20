import Foundation

/// `CameraCapture` orchestrator. Wraps a `VideoCapture` collaborator
/// and on every raw BGRA frame:
///
///   1. assigns a monotonic sequence number (per session — resets on start)
///   2. strips row padding via `BGRAConverter`
///   3. forwards the tightly-packed `CameraFrame` to the caller's `onFrame`
///
/// The actual `AVCaptureSession` plumbing lives behind `HostVideoCapture`
/// (~50 LOC, integration-only). This orchestrator is unit-covered
/// end-to-end via `MockVideoCapture`.
final class AVCameraCapture: CameraCapture, @unchecked Sendable {
    private let video: any VideoCapture
    private let lock = NSLock()
    private var sequence: UInt32 = 0
    private var dropCount: UInt64 = 0

    init(video: any VideoCapture) {
        self.video = video
    }

    convenience init() {
        self.init(video: HostVideoCapture())
    }

    func start(
        device: CameraDevice,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) async throws {
        resetSequence()
        try await video.start(deviceUniqueID: device.uid) { [weak self] raw in
            guard let self else { return }
            let seq = self.nextSequence()
            do {
                let frame = try BGRAConverter.convert(
                    baseAddress: raw.baseAddress,
                    width: raw.width,
                    height: raw.height,
                    bytesPerRow: raw.bytesPerRow,
                    sequence: seq,
                    timestampMs: raw.timestampMs
                )
                onFrame(frame)
            } catch {
                // Single-frame conversion failures are non-fatal but
                // should be visible — silently dropping every frame
                // looks identical to "the dylib's not loaded" from
                // the user's POV. Log once per 60 dropped frames so
                // the operator sees the symptom without log spam.
                self.recordDrop(error: error)
            }
        }
    }

    func stop() async {
        await video.stop()
    }

    private func nextSequence() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    private func resetSequence() {
        lock.lock(); defer { lock.unlock() }
        sequence = 0
        dropCount = 0
    }

    private func recordDrop(error: Error) {
        lock.lock()
        dropCount &+= 1
        let shouldLog = dropCount == 1 || dropCount % 60 == 0
        let total = dropCount
        lock.unlock()
        if shouldLog {
            FileHandle.standardError.write(Data(
                "[camera] dropped \(total) frame(s) — last: \(error)\n".utf8
            ))
        }
    }
}
