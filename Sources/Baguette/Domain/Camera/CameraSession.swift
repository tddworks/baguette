import Foundation

/// Owns the camera-streaming state machine for one simulator. Drives
/// three collaborators:
///
///   • `SimulatorInjection`  — arms the dylib env on the target sim
///   • `CameraCapture`       — pulls BGRA frames off a Mac camera
///   • `FrameSink`           — writes those frames into the shared buffer
///
/// `@MainActor` because the WS handler hops here from the NIO event
/// loop and we want a single ordering for state mutations. Frames
/// arrive on the capture queue and re-enter via `Task { @MainActor }`.
@MainActor
final class CameraSession {

    enum Phase: Equatable, Sendable {
        case idle
        case streaming(source: CameraSource)
    }

    private(set) var phase: Phase = .idle
    private(set) var fps: Double = 0
    private(set) var lastError: String?
    private(set) var startedAt: Date?
    private(set) var flags: CameraFlags = CameraFlags()

    /// Capture has stopped, but removing the guest injection still needs an explicit stop.
    var cleanupRequired: Bool { phase == .idle && armedSimulator != nil }

    private let webcam: any CameraCapture
    private let image: any CameraCapture
    private let video: any CameraCapture
    private let sink: any CameraFrameSink
    private let injection: any SimulatorInjection
    private let guestTerminated: (String) throws -> Bool

    /// The capture serving the current stream — retained so `stop`
    /// tears down exactly the producer that `start` selected.
    private var activeCapture: (any CameraCapture)?

    /// The simulator whose launchd domain we armed with
    /// `DYLD_INSERT_LIBRARIES` — retained so `stop` disarms it. Leaving
    /// it armed loads the dylib into every future app launch on that
    /// sim until it reboots, so teardown must unset it.
    private var armedSimulator: (any Simulator)?

    /// The dylib path `start` armed — retained because the variable is
    /// shared with other injecting features, so teardown has to name its
    /// own entry rather than dropping whatever else is loaded.
    private var armedDylibPath: String?
    private var cleanupTask: Task<Void, Never>?

    private var frameCount: UInt64 = 0
    private var fpsLastSample: (Date, UInt64)?

    init(
        webcam: any CameraCapture,
        image: any CameraCapture,
        video: any CameraCapture,
        sink: any CameraFrameSink,
        injection: any SimulatorInjection,
        guestTerminated: @escaping (String) throws -> Bool
    ) {
        self.webcam = webcam
        self.image = image
        self.video = video
        self.sink = sink
        self.injection = injection
        self.guestTerminated = guestTerminated
    }

    /// The producer that owns `source`. The session is the single place
    /// that maps a source to its capture — no composite abstraction.
    private func capture(for source: CameraSource) -> any CameraCapture {
        switch source {
        case .device: return webcam
        case .image: return image
        case .video: return video
        }
    }

    /// Replace the display preferences shipped with each frame. Takes
    /// effect on the next captured frame; no restart.
    func setFlags(_ flags: CameraFlags) {
        self.flags = flags
    }

    /// Arm the dylib on `simulator` and start pulling frames off
    /// `source`. On any failure the session stays `.idle` with
    /// `lastError` populated; callers can read both fields without
    /// catching.
    func start(source: CameraSource, on simulator: any Simulator, dylibPath: String) async {
        if let cleanupTask { await cleanupTask.value }
        guard !cleanupRequired else { return }
        guard case .idle = phase else { return }
        do {
            try await injection.arm(dylibPath: dylibPath, on: simulator)
        } catch {
            lastError = error.localizedDescription
            return
        }
        armedSimulator = simulator
        armedDylibPath = dylibPath
        let capture = capture(for: source)
        do {
            try await capture.start(source: source) { [weak self] frame in
                Task { @MainActor in self?.deliver(frame) }
            }
        } catch {
            let captureError = error.localizedDescription
            await disarm()
            lastError = [captureError, lastError].compactMap { $0 }.joined(separator: "; ")
            return
        }
        activeCapture = capture
        phase = .streaming(source: source)
        startedAt = Date()
        frameCount = 0
        fpsLastSample = nil
        lastError = nil
    }

    /// A restarted server has no arm history; explicit stop must still remove the selected guest's injection.
    func stop(on simulator: any Simulator, dylibPath: String) async {
        if armedSimulator == nil {
            armedSimulator = simulator
            armedDylibPath = dylibPath
        }
        await stop()
    }

    /// Tear the stream down and disarm the dylib.
    ///
    /// Concurrent callers await the same cleanup. Failed disarming keeps
    /// the target and error, so only a later explicit stop retries it.
    func stop() async {
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        let task = Task { await tearDown() }
        cleanupTask = task
        await task.value
        cleanupTask = nil
    }

    private func tearDown() async {
        let capture = activeCapture
        phase = .idle
        activeCapture = nil
        startedAt = nil
        fps = 0
        fpsLastSample = nil

        await capture?.stop()
        await disarm()
    }

    private func disarm() async {
        lastError = nil
        guard let sim = armedSimulator, let dylibPath = armedDylibPath else { return }
        do {
            try await injection.disarm(dylibPath: dylibPath, on: sim)
            armedSimulator = nil
            armedDylibPath = nil
        } catch {
            let failure =
                "Camera injection cleanup failed on \(sim.udid): \(error.localizedDescription). Stop again to retry cleanup before starting another camera."
            do {
                if try guestTerminated(sim.udid) {
                    armedSimulator = nil
                    armedDylibPath = nil
                    return
                }
                lastError = failure
            } catch {
                lastError = "\(failure) Guest termination could not be confirmed: \(error.localizedDescription)"
            }
        }
    }

    /// Tick called by the WS heartbeat (once per second). Computes
    /// instantaneous FPS from the frame-counter delta since the last
    /// sample; first call seeds the baseline and returns fps=0.
    func sampleFPS() {
        let now = Date()
        let count = frameCount
        if let prev = fpsLastSample {
            let dt = now.timeIntervalSince(prev.0)
            let dCount = count >= prev.1 ? count - prev.1 : 0
            fps = dt > 0 ? Double(dCount) / dt : 0
        }
        fpsLastSample = (now, count)
    }

    // MARK: - Frame delivery

    private func deliver(_ frame: CameraFrame) {
        do {
            try sink.write(frame, flags: flags)
            frameCount &+= 1
        } catch {
            lastError = error.localizedDescription
        }
    }
}
