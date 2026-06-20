import Foundation

/// Production `Subprocess` — wraps a `Foundation.Process` plus a
/// stdout/stderr `Pipe`. The only Infrastructure code in the logs
/// path that touches the real OS spawn pipeline. Integration-only
/// (manually smoke-tested via `baguette logs` against a booted
/// simulator); the orchestrator's behaviour is unit-covered
/// against `MockSubprocess`.
///
/// Single-shot — one `run(...)` call per instance. Re-running
/// would risk leaking the previous Process / Pipe.
final class HostSubprocess: Subprocess, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var pipe: Pipe?

    init() {}

    deinit {
        if let process, process.isRunning { process.terminate() }
        try? pipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
    }

    func run(
        executable: URL,
        arguments: [String],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit:  @escaping @Sendable (Int32) -> Void
    ) throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError  = pipe
        // Detach from any controlling terminal. Without this a
        // SIGINT handed to the parent (Ctrl-C in `baguette logs`)
        // would also kill the child via the foreground pgid
        // before the parent's own SIGTERM handler runs.
        process.standardInput  = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if !bytes.isEmpty { onBytes(bytes) }
        }
        process.terminationHandler = { proc in
            onExit(proc.terminationStatus)
        }

        lock.lock()
        self.pipe = pipe
        self.process = process
        lock.unlock()

        try process.run()
    }

    func terminate() {
        lock.lock()
        let proc = self.process
        let pipe = self.pipe
        lock.unlock()
        if let proc, proc.isRunning { proc.terminate() }
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
    }
}
