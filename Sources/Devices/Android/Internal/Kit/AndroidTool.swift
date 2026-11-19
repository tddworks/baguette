import BaguetteDevice
import Foundation

/// An Android SDK tool run as a child: `adb` — the Android Debug Bridge, the
/// one door into every Android device, emulators and phones alike — or the
/// `emulator`. One child per call; what it printed comes back, and a non-zero
/// exit fails with the tool's last line. A tool that doesn't answer within
/// `timeout` is stopped and refused: a hung adb must not hold up every
/// device lookup behind it.
struct AndroidTool: Sendable {
    private let executable: URL
    private let timeout: TimeInterval
    private let makeSubprocess: @Sendable () -> any Subprocess

    init(executable: URL, timeout: TimeInterval = 15,
         makeSubprocess: @escaping @Sendable () -> any Subprocess = { HostSubprocess() }) {
        self.executable = executable
        self.timeout = timeout
        self.makeSubprocess = makeSubprocess
    }

    /// The adb this Mac has, or nil when it has none.
    static var adb: AndroidTool? { AndroidSDKLocation.adb().map { AndroidTool(executable: $0) } }
    /// The Android Emulator this Mac has, or nil when it has none.
    static var emulator: AndroidTool? { AndroidSDKLocation.emulator().map { AndroidTool(executable: $0) } }

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
        guard done.wait(timeout: .now() + timeout) == .success else {
            subprocess.terminate()
            throw AdbError.timedOut
        }
        return try outcome.get()
    }

    private static func lastLine(of data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

extension AndroidTool {
    /// The screen of the device `serial` names, in pixels (`wm size`); a
    /// Pixel's 1080 × 2400 when adb can't say.
    func screenPixels(of serial: String) -> Size {
        AndroidScreenSize.pixels(fromWmSize: wm("size", serial)) ?? Size(width: 1080, height: 2400)
    }

    /// Its pixels per point (`wm density` ÷ 160); a Pixel's 2.625 when adb can't say.
    func pixelsPerPoint(of serial: String) -> Double {
        AndroidScreenSize.pixelsPerPoint(fromWmDensity: wm("density", serial)) ?? 2.625
    }

    private func wm(_ what: String, _ serial: String) -> String {
        (try? runAndWait(["-s", serial, "shell", "wm", what])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

enum AdbError: Error, Equatable, CustomStringConvertible {
    case failed(status: Int32, message: String)
    case timedOut

    var description: String {
        switch self {
        case let .failed(status, message): message.isEmpty ? "adb exited \(status)" : message
        case .timedOut: "adb didn't answer in time"
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
