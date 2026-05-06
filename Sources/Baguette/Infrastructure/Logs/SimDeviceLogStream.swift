import Foundation

/// Production `LogStream` — runs `xcrun simctl spawn <udid> log
/// stream …` as a host child process, line-buffers its stdout
/// back to the consumer.
///
/// Why not call `SimDevice.spawnWith…` directly from CoreSimulator?
/// The signature is published and a direct call *almost* works,
/// but on iOS-26 simulators the spawned `/usr/bin/log` rejects the
/// invocation with "Must be admin to run 'stream' command" — the
/// CoreSimulator daemon's spawn pipeline runs the child with a
/// bootstrap context that fails `log`'s membership check unless
/// the calling process is `simctl` (Apple-signed and known to
/// `com.apple.CoreSimulator.CoreSimulatorService`). Shelling out
/// to `simctl` sidesteps that entitlement gap; it's guaranteed
/// installed alongside the device set we're already targeting.
///
/// One spawn per `start(...)` call; multiple parallel subscribers
/// are fine (each instance is independent), but a single instance
/// rejects a second `start` — re-issue a fresh `LogStream`.
final class SimDeviceLogStream: LogStream, @unchecked Sendable {
    private let udid: String
    private weak var host: CoreSimulators?

    private let lock = NSLock()
    private var process: Process?
    private var pipe: Pipe?
    private var lineBuffer = Data()
    private var started = false
    private var stopped = false
    private var onLineCb: (@Sendable (String) -> Void)?
    private var onTermCb: (@Sendable (Error?) -> Void)?

    init(udid: String, host: CoreSimulators) {
        self.udid = udid
        self.host = host
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
        try? pipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
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
        guard let device = host?.resolveDevice(udid: udid) else {
            lock.unlock()
            throw LogStreamError.simulatorNotBooted(udid: udid)
        }
        let stateRaw = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        guard stateRaw == 3 else {
            lock.unlock()
            throw LogStreamError.simulatorNotBooted(udid: udid)
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // simctl args: spawn <udid> <argv0> <argv1...>. We strip the
        // synthetic `log` argv[0] from filter.argv since simctl
        // appends it itself; what simctl wants is the binary name
        // as the first positional, which it then runs inside the
        // simulator's user context. Pass `log` (the binary), then
        // `stream …` (the subcommand + flags).
        process.arguments = ["simctl", "spawn", udid] + filter.argv
        process.standardOutput = pipe
        process.standardError  = pipe
        // Detach from any controlling terminal. Without this a
        // SIGINT handed to the parent (Ctrl-C in `baguette logs`)
        // would also kill the child via the foreground pgid before
        // our own SIGTERM handler runs.
        process.standardInput  = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment

        self.pipe = pipe
        self.process = process
        self.onLineCb = onLine
        self.onTermCb = onTerminate
        self.started = true
        lock.unlock()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { return }
            self?.consume(bytes)
        }

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // SIGTERM (status 15 / negative-signal codes via Process)
            // is intentional — caused by `stop()`. Anything else is
            // a real exit and we surface it.
            if status == 0 {
                self?.handleTermination(error: nil)
            } else {
                self?.handleTermination(error: LogStreamError.nonZeroExit(code: status))
            }
        }

        do {
            try process.run()
        } catch {
            unwireAfterSpawnFailure(pipe: pipe)
            throw LogStreamError.spawnFailed(reason: error.localizedDescription)
        }
        log("[logs] simctl spawn pid=\(process.processIdentifier) udid=\(udid)")
    }

    func stop() {
        lock.lock()
        guard started, !stopped else { lock.unlock(); return }
        stopped = true
        let proc = self.process
        let pipe = self.pipe
        let term = self.onTermCb
        self.onLineCb = nil
        self.onTermCb = nil
        lock.unlock()

        if let proc, proc.isRunning {
            proc.terminate()
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
        term?(nil)
    }

    // MARK: - private

    private func unwireAfterSpawnFailure(pipe: Pipe) {
        lock.lock()
        self.pipe = nil
        self.process = nil
        self.onLineCb = nil
        self.onTermCb = nil
        self.started = false
        lock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    private func consume(_ bytes: Data) {
        lock.lock()
        guard !stopped, let cb = onLineCb else {
            lock.unlock()
            return
        }
        lineBuffer.append(bytes)
        var lines: [String] = []
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) {
                lines.append(s)
            }
        }
        lock.unlock()
        for line in lines { cb(line) }
    }

    private func handleTermination(error: Error?) {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let term = onTermCb
        let pipe = self.pipe
        onLineCb = nil
        onTermCb = nil
        lock.unlock()
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForReading.close()
        term?(error)
    }
}
