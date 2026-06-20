import Foundation

/// `LogStream` orchestrator. Owns the state machine —
/// already-started, stopped, line buffering, error mapping — and
/// delegates the actual OS-level spawn to a `Subprocess`
/// collaborator. The `Subprocess` is the only piece in the path
/// that touches `Foundation.Process` / `Pipe` / `kill(pid)`;
/// `SimDeviceLogStream` itself is pure logic and ~100% unit-
/// covered via `MockSubprocess`.
///
/// One spawn per `start(...)` call; multiple parallel subscribers
/// are fine (each instance owns its own subprocess), but a
/// single instance rejects a second `start` — re-issue a fresh
/// `LogStream` instead.
final class SimDeviceLogStream: LogStream, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost
    private let subprocess: any Subprocess

    private let lock = NSLock()
    private var lineBuffer = LineBuffer()
    private var started = false
    private var stopped = false
    private var onLineCb: (@Sendable (String) -> Void)?
    private var onTermCb: (@Sendable (Error?) -> Void)?

    /// Production callers default to `HostSubprocess()` (a thin
    /// `Foundation.Process` wrapper). Tests inject `MockSubprocess`
    /// to drive the state machine deterministically.
    init(udid: String, host: any DeviceHost, subprocess: any Subprocess = HostSubprocess()) {
        self.udid = udid
        self.host = host
        self.subprocess = subprocess
    }

    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    // MARK: - LogStream

    func start(
        filter: LogFilter,
        onLine: @escaping @Sendable (String) -> Void,
        onTerminate: @escaping @Sendable (Error?) -> Void
    ) throws {
        lock.lock()
        if started {
            lock.unlock()
            throw LogStreamError.alreadyStarted
        }
        guard let device = resolveDevice() else {
            lock.unlock()
            throw LogStreamError.simulatorNotBooted(udid: udid)
        }
        let stateRaw = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        guard stateRaw == 3 else {
            lock.unlock()
            throw LogStreamError.simulatorNotBooted(udid: udid)
        }
        self.onLineCb = onLine
        self.onTermCb = onTerminate
        self.started = true
        lock.unlock()

        // Always shell out via `xcrun simctl spawn` — the direct
        // `SimDevice.spawn…` path on iOS 26 fails the simulator's
        // admin-group check unless the caller is Apple-signed
        // (which simctl is and we aren't). simctl is guaranteed
        // installed alongside the device set we're targeting, so
        // the indirection is cheap. Argv: simctl args + filter argv.
        let argv = ["simctl", "spawn", udid] + filter.argv

        do {
            try subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: argv,
                onBytes: { [weak self] bytes in self?.consume(bytes) },
                onExit:  { [weak self] code  in self?.handleExit(code) }
            )
        } catch {
            // Spawn failed synchronously: clear state so a future
            // re-issue isn't blocked by the `alreadyStarted` flag,
            // and surface the failure to the caller.
            lock.lock()
            self.onLineCb = nil
            self.onTermCb = nil
            self.started = false
            lock.unlock()
            throw LogStreamError.spawnFailed(reason: error.localizedDescription)
        }
        log("[logs] subprocess spawned for udid=\(udid)")
    }

    func stop() {
        lock.lock()
        guard started, !stopped else { lock.unlock(); return }
        stopped = true
        let term = onTermCb
        onLineCb = nil
        onTermCb = nil
        lock.unlock()

        subprocess.terminate()
        term?(nil)
    }

    // MARK: - private

    private func consume(_ bytes: Data) {
        lock.lock()
        guard !stopped, let cb = onLineCb else {
            lock.unlock()
            return
        }
        let lines = lineBuffer.append(bytes)
        lock.unlock()
        for line in lines { cb(line) }
    }

    private func handleExit(_ status: Int32) {
        lock.lock()
        // `stop()` flips `stopped` first and fires onTerminate
        // synchronously, so a follow-up onExit from the dying
        // child has nothing left to report. Drop it.
        if stopped { lock.unlock(); return }
        stopped = true
        let term = onTermCb
        onLineCb = nil
        onTermCb = nil
        lock.unlock()

        if status == 0 {
            term?(nil)
        } else {
            term?(LogStreamError.nonZeroExit(code: status))
        }
    }
}
