import BaguetteDevice
import Foundation

/// `WatchPairing` backed by `xcrun simctl list pairs -j`.
///
/// The pairing table is host-wide and cheap to read, so there is no
/// caching here — the rail asks once per page load, and a pair created
/// while the tab is open should show up on the next ask rather than
/// after a restart. Everything except the spawn is
/// `SimctlPairs.watch(pairedWith:in:)`, which is unit-covered; a spawn
/// that fails — or stalls past its deadline — yields no watch, same as
/// a phone that has none.
final class SimctlWatchPairing: WatchPairing, @unchecked Sendable {
    private let udid: String
    private let listPairs: () throws -> String

    init(udid: String, listPairs: @escaping () throws -> String) {
        self.udid = udid
        self.listPairs = listPairs
    }

    /// `deviceSetPath` is the custom device set the phone lives in; each
    /// set keeps its own pairing table.
    convenience init(udid: String, deviceSetPath: String? = nil) {
        self.init(udid: udid, listPairs: { try SimctlPairsCapture.list(deviceSetPath: deviceSetPath) })
    }

    var watch: PairedWatch? {
        guard let json = try? listPairs() else { return nil }
        return SimctlPairs.watch(pairedWith: udid, in: json)
    }
}

/// Synchronous `xcrun simctl list pairs -j` capture.
enum SimctlPairsCapture {
    /// `simctl list pairs` normally answers in milliseconds, but it goes
    /// through CoreSimulatorService — and a wedged service leaves the
    /// call hanging with no deadline of its own. This runs inline on the
    /// companion-screens request, so an unbounded wait is a request that
    /// never answers rather than a slow one.
    ///
    /// A phone whose pairing table can't be read is the same answer as a
    /// phone with no watch, so the deadline yields that instead of
    /// waiting for one that isn't coming.
    static let defaultTimeout: TimeInterval = 5

    static func list(
        deviceSetPath: String? = nil,
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        timeout: TimeInterval = defaultTimeout
    ) throws -> String {
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["list", "pairs", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment
        try process.run()

        // Read on another thread so the deadline lands on the wait
        // rather than on the read. `readDataToEndOfFile` is unbounded
        // too: a child that has stopped writing without exiting sits
        // there just as long as `waitUntilExit` would.
        let output = CapturedOutput()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.store(pipe.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return ""
        }
        process.waitUntilExit()
        return output.text()
    }
}

/// Somewhere for the reader thread to leave the child's stdout that the
/// waiting thread can read it back from.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
