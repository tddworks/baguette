import BaguetteDevice
import Foundation

/// `adb` — the Android Debug Bridge, the one door into every Android device:
/// emulators and phones alike, on a cable or over Wi-Fi. One child per call;
/// what it printed comes back, and a non-zero exit fails with adb's last line.
struct Adb: Sendable {
    private let executable: URL
    private let makeSubprocess: @Sendable () -> any Subprocess

    init(executable: URL, makeSubprocess: @escaping @Sendable () -> any Subprocess = { HostSubprocess() }) {
        self.executable = executable
        self.makeSubprocess = makeSubprocess
    }

    /// The adb this Mac has (`AdbLocation`), or nil when it has none.
    static var installed: Adb? { AdbLocation.find().map { Adb(executable: $0) } }

    /// Run `adb <arguments>`, blocking until it exits.
    func runAndWait(_ arguments: [String]) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        let outcome = AdbOutcome()
        let output = AdbOutput()
        // A subprocess ends its child when it is released, so the exit
        // handler holds it until adb has finished.
        let subprocess = makeSubprocess()
        try subprocess.run(
            executable: executable, arguments: arguments,
            onBytes: { output.append($0) },
            onExit: { status in
                withExtendedLifetime(subprocess) {}
                outcome.set(status == 0 ? .success(output.data)
                            : .failure(AdbError.failed(status: status, message: Self.lastLine(of: output.data))))
                done.signal()
            })
        done.wait()
        return try outcome.get()
    }

    private static func lastLine(of data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

enum AdbError: Error, Equatable, CustomStringConvertible {
    case failed(status: Int32, message: String)

    var description: String {
        switch self {
        case let .failed(status, message): message.isEmpty ? "adb exited \(status)" : message
        }
    }
}

private final class AdbOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}

private final class AdbOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, any Error> = .success(Data())
    func set(_ result: Result<Data, any Error>) { lock.withLock { self.result = result } }
    func get() throws -> Data { try lock.withLock { result }.get() }
}
