import Foundation

/// `Hinge` read inside the guest: `xcrun simctl spawn <udid> <HingeControl>
/// read-angle` prints the current angle and exits, `watch-angle` prints
/// every sample until stopped. Both read CoreMotion's `CMAngleManager`,
/// as the runtime's own device-info daemon does.
///
/// The first sample carries the current angle and arrives in ~0.6 s with
/// the spawn, before any motion — so this spawns the reader, takes that
/// sample, and terminates the child. A failed exit (a device with no
/// hinge, a silent guest), a missing `HingeControl`, or a child that has
/// printed nothing by `deadline` is "no reading".
///
/// The orchestration — tool lookup, argv, byte-to-line splitting,
/// first-sample detection, terminate, deadline — is unit-covered through
/// `MockSubprocess`; only `HostSubprocess`'s `Process` plumbing is
/// integration-only.
final class GuestHinge: Hinge, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    /// A fresh child per call: `angle()` and each `watch` own their
    /// own reader and terminate only that one.
    private let subprocess: () -> any Subprocess
    private let tool: () -> String?
    private let xcrun: URL
    private let deadline: TimeInterval

    init(
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: @escaping () -> any Subprocess = { HostSubprocess() },
        tool: @escaping () -> String? = { InjectedDylibInstaller.installIfNeeded(.hingeControl) },
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        deadline: TimeInterval = 3
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.tool = tool
        self.xcrun = xcrun
        self.deadline = deadline
    }

    func angle() -> HingeAngle? {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var buffer = LineBuffer()
            var reading: HingeAngle?
            var settled = false
            let done = DispatchSemaphore(value: 0)

            func settle(_ angle: HingeAngle?) {
                lock.lock()
                defer { lock.unlock() }
                guard !settled else { return }
                settled = true
                reading = angle
                done.signal()
            }
        }
        guard let arguments = arguments(verb: "read-angle") else { return nil }
        let state = State()
        let child = subprocess()
        do {
            try child.run(
                executable: xcrun,
                arguments: arguments,
                onBytes: { bytes in
                    state.lock.lock()
                    let lines = state.buffer.append(bytes)
                    state.lock.unlock()
                    for line in lines {
                        if let angle = HingeAngle.parse(hingeControlLine: line) {
                            state.settle(angle)
                            return
                        }
                    }
                },
                // A clean exit means a sample was printed, and the pipe can
                // deliver it after the exit; the deadline bounds that wait.
                onExit: { status in if status != 0 { state.settle(nil) } }
            )
        } catch {
            return nil
        }
        _ = state.done.wait(timeout: .now() + deadline)
        state.settle(nil)
        child.terminate()
        return state.reading
    }

    /// This only reads; `SharedHinge` drives through its motor.
    func fold(to degrees: Double, over duration: TimeInterval) throws {
        throw HingeError.toolMissing
    }

    /// Nor does it play sweeps to tell of.
    func watchSweeps(onSweep: @escaping @Sendable (HingeSweepEvent) -> Void) -> any HingeWatch {
        Unheard()
    }

    private struct Unheard: HingeWatch {
        func cancel() {}
    }

    func watch(onAngle: @escaping @Sendable (HingeAngle) -> Void) -> any HingeWatch {
        let watch = Watch(child: subprocess())
        guard let arguments = arguments(verb: "watch-angle") else {
            watch.cancel()
            return watch
        }
        do {
            try watch.child.run(
                executable: xcrun,
                arguments: arguments,
                onBytes: { bytes in
                    for line in watch.lines(from: bytes) {
                        if let angle = HingeAngle.parse(hingeControlLine: line) {
                            onAngle(angle)
                        }
                    }
                },
                onExit: { _ in watch.cancel() }
            )
        } catch {
            watch.cancel()
        }
        return watch
    }

    /// `nil` when the build carries no `HingeControl`.
    private func arguments(verb: String) -> [String]? {
        guard let tool = tool() else { return nil }
        return ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["spawn", udid, tool, verb]
    }

    private final class Watch: HingeWatch, @unchecked Sendable {
        let child: any Subprocess
        private let lock = NSLock()
        private var buffer = LineBuffer()
        private var cancelled = false

        init(child: any Subprocess) { self.child = child }

        /// Lines completed by `bytes`, or none once cancelled — a
        /// sample the pipe still held must not reach a caller that has
        /// moved on.
        func lines(from bytes: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return [] }
            return buffer.append(bytes)
        }

        func cancel() {
            lock.lock()
            let first = !cancelled
            cancelled = true
            lock.unlock()
            if first { child.terminate() }
        }
    }
}
