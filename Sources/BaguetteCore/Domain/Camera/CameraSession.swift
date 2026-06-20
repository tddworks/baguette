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
        case streaming(deviceUID: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var fps: Double = 0
    private(set) var lastError: String?
    private(set) var startedAt: Date?
    private(set) var flags: CameraFlags = CameraFlags()

    private let capture: any CameraCapture
    private let sink: any CameraFrameSink
    private let injection: any SimulatorInjection

    private var frameCount: UInt64 = 0
    private var fpsLastSample: (Date, UInt64)?

    init(
        capture: any CameraCapture,
        sink: any CameraFrameSink,
        injection: any SimulatorInjection
    ) {
        self.capture = capture
        self.sink = sink
        self.injection = injection
    }

    /// Replace the display preferences shipped with each frame. Takes
    /// effect on the next captured frame; no restart.
    func setFlags(_ flags: CameraFlags) {
        self.flags = flags
    }

    /// Arm the dylib on `simulator` and start pulling frames off
    /// `device`. On any failure the session stays `.idle` with
    /// `lastError` populated; callers can read both fields without
    /// catching.
    func start(device: CameraDevice, on simulator: any Simulator, dylibPath: String) async {
        guard case .idle = phase else { return }
        do {
            try await injection.arm(dylibPath: dylibPath, on: simulator)
        } catch {
            lastError = error.localizedDescription
            return
        }
        do {
            try await capture.start(device: device) { [weak self] frame in
                Task { @MainActor in self?.deliver(frame) }
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        phase = .streaming(deviceUID: device.uid)
        startedAt = Date()
        frameCount = 0
        fpsLastSample = nil
        lastError = nil
    }

    func stop() async {
        guard case .streaming = phase else { return }
        await capture.stop()
        phase = .idle
        startedAt = nil
        fps = 0
        fpsLastSample = nil
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
