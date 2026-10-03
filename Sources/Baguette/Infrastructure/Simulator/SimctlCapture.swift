import Foundation

/// Bounded simctl output, including process exit and both output channels.
enum SimctlCapture {
    struct Output {
        let stdout: String
        let stderr: String
        var combined: String { stdout + stderr }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case timedOut(udid: String, seconds: TimeInterval, processExited: Bool, output: String)
        case failed(udid: String, status: Int32, output: String)
        case outputReadFailed(udid: String, code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let udid, let seconds, let processExited, let output):
                let state = processExited ? "exited" : "running"
                return "Simulator query for \(udid) timed out after \(seconds)s (process reported \(state)): \(output)"
            case .failed(let udid, let status, let output):
                return "Simulator query for \(udid) exited with status \(status): \(output)"
            case .outputReadFailed(let udid, let code, let output):
                return "Simulator query for \(udid) could not read output (errno \(code)): \(output)"
            }
        }
    }

    static func enumerate(
        udid: String,
        deviceSetPath: String? = nil,
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        timeout: TimeInterval = 5,
        process: Process = Process()
    ) throws -> String {
        try run(
            udid: udid,
            arguments: ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["io", udid, "enumerate"],
            xcrun: xcrun, timeout: timeout, process: process
        ).combined
    }

    static func run(
        udid: String,
        arguments: [String],
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        timeout: TimeInterval = 5,
        process: Process = Process()
    ) throws -> Output {
        process.executableURL = xcrun
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let stdout = CapturedOutput(stdoutPipe.fileHandleForReading)
        let stderr = CapturedOutput(stderrPipe.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        let complete = DispatchGroup()
        // Process exit and one reader completion per output channel.
        complete.enter()
        complete.enter()
        complete.enter()
        defer {
            if stdout.close() { complete.leave() }
            if stderr.close() { complete.leave() }
        }
        process.terminationHandler = { _ in
            exited.signal()
            complete.leave()
        }
        do {
            try process.run()
        } catch {
            complete.leave()
            throw error
        }
        // A readability source, unlike DispatchIO, needs no free global-queue worker to
        // make progress, so a host with every worker blocked still drains the pipe.
        for (pipe, output) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
            pipe.fileHandleForReading.readabilityHandler = { _ in
                switch output.drain() {
                case .more: return
                case .failed: if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                case .end: break
                }
                if output.close() { complete.leave() }
            }
        }
        guard complete.wait(timeout: .now() + timeout) == .success else {
            // A stalled simctl can ignore SIGTERM. Request termination, then bound the exit wait.
            let processExited = !process.isRunning
            if !processExited { Darwin.kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 1)
            throw Failure.timedOut(
                udid: udid, seconds: timeout, processExited: processExited,
                output: stdout.result.text + stderr.result.text
            )
        }
        let out = stdout.result
        let err = stderr.result
        let output = Output(stdout: out.text, stderr: err.text)
        let readError = out.error != 0 ? out.error : err.error
        guard readError == 0 else {
            throw Failure.outputReadFailed(udid: udid, code: readError, output: output.combined)
        }
        guard process.terminationStatus == 0 else {
            throw Failure.failed(udid: udid, status: process.terminationStatus, output: output.combined)
        }
        return output
    }

    /// Owns the read end of the pipe. Reads and the close share one lock, so a
    /// readability callback still in flight never reads a closed (or reused) descriptor.
    private final class CapturedOutput: @unchecked Sendable {
        enum Chunk { case more, end, failed }

        private let handle: FileHandle
        private let lock = NSLock()
        private var bytes = Data()
        private var readError: Int32 = 0
        private var closed = false

        init(_ handle: FileHandle) { self.handle = handle }

        func drain() -> Chunk {
            lock.withLock {
                guard !closed else { return .end }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count > 0 {
                        bytes.append(contentsOf: buffer[..<count])
                        return .more
                    }
                    if count == 0 { return .end }
                    if errno == EINTR { continue }
                    if errno == EAGAIN { return .more }
                    readError = errno
                    return .failed
                }
            }
        }

        /// Stops the readability source, then closes the descriptor. Returns `true` only
        /// for the call that actually closed it.
        @discardableResult
        func close() -> Bool {
            handle.readabilityHandler = nil
            return lock.withLock {
                guard !closed else { return false }
                closed = true
                try? handle.close()
                return true
            }
        }

        var result: (text: String, error: Int32) {
            lock.withLock { (String(decoding: bytes, as: UTF8.self), readError) }
        }
    }
}
