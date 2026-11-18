import Foundation

/// `xcrun devicectl` — the public door into CoreDevice, shared by every
/// adapter in the CoreDevice family. One child per call; what it printed
/// comes back, and a non-zero exit fails with devicectl's last line.
struct Devicectl: Sendable {
    private let makeSubprocess: @Sendable () -> any Subprocess
    private let xcrun: URL

    init(
        makeSubprocess: @escaping @Sendable () -> any Subprocess = { HostSubprocess() },
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.makeSubprocess = makeSubprocess
        self.xcrun = xcrun
    }

    /// Run `devicectl <arguments>`, feeding `stdin` when given.
    func run(_ arguments: [String], stdin: Data? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            start(arguments, stdin: stdin) { continuation.resume(with: $0) }
        }
    }

    /// `run`, for a caller that can't wait asynchronously (`Orientation.set`,
    /// `Devices.all`). Blocks the calling thread until devicectl exits.
    func runAndWait(_ arguments: [String]) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        start(arguments, stdin: nil) { result in
            outcome.set(result)
            done.signal()
        }
        done.wait()
        return try outcome.get()
    }

    private func start(
        _ arguments: [String], stdin: Data?,
        completion: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) {
        let output = Output()
        let argv = ["devicectl"] + arguments
        // A subprocess ends its child when it is released, so the exit
        // handler holds it until devicectl has finished.
        let subprocess = makeSubprocess()
        let onBytes: @Sendable (Data) -> Void = { output.append($0) }
        let onExit: @Sendable (Int32) -> Void = { status in
            withExtendedLifetime(subprocess) {}
            let bytes = output.data
            if status == 0 {
                completion(.success(bytes))
            } else {
                completion(.failure(DevicectlError.failed(status: status, message: Self.lastLine(of: bytes))))
            }
        }
        do {
            if let stdin {
                try subprocess.run(executable: xcrun, arguments: argv, stdin: stdin, onBytes: onBytes, onExit: onExit)
            } else {
                try subprocess.run(executable: xcrun, arguments: argv, onBytes: onBytes, onExit: onExit)
            }
        } catch {
            completion(.failure(error))
        }
    }

    private static func lastLine(of data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last.map(String.init) ?? ""
    }
}

enum DevicectlError: Error, Equatable, CustomStringConvertible {
    case failed(status: Int32, message: String)

    var description: String {
        switch self {
        case let .failed(status, message):
            return message.isEmpty ? "devicectl exited \(status)" : message
        }
    }
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, any Error> = .success(Data())
    func set(_ result: Result<Data, any Error>) { lock.withLock { self.result = result } }
    func get() throws -> Data { try lock.withLock { result }.get() }
}
