import Foundation

/// `Pasteboard` backed by `xcrun simctl pbcopy | pbpaste | pbsync`,
/// with `xcrun devicectl device pasteboard copy` asked first for writes.
///
/// Under Xcode 27 `simctl pbcopy` exits 0 and writes nothing (measured
/// on iOS 26.5, 27.0 and 27.1 guests), while Core Device's copy lands
/// and `simctl pbpaste` reads it back. So `setText` tries devicectl
/// first and falls back to `pbcopy` when it exits non-zero — an Xcode
/// without the subcommand (usage error, 64), or one that does not know
/// the device. No version check: an Xcode 26 host keeps the route that
/// works there. Core Device only sees the default device set, so a
/// device in a custom set (`--device-set`) goes straight to `pbcopy`.
///
/// The orchestration here is pure: argv assembly + the `Subprocess`
/// exit handshake, with the paste text riding the child's stdin
/// (`pbcopy` reads its payload there — the reason `Subprocess` grew
/// a stdin-carrying `run` variant). The `Foundation.Process`
/// plumbing lives in `HostSubprocess` (already vendored for
/// `LogStream`), so this file is unit-covered end-to-end via
/// `MockSubprocess` — only the real spawn is integration-only.
final class SimctlPasteboard: Pasteboard, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    private let subprocess: any Subprocess
    private let xcrun: URL

    init(
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.xcrun = xcrun
    }

    func setText(_ text: String) async throws {
        let payload = Data(text.utf8)
        if deviceSetPath == nil,
           try await write(["devicectl", "device", "pasteboard", "copy", "--device", udid], stdin: payload) == 0 {
            return
        }
        let status = try await write(simctl(["pbcopy", udid]), stdin: payload)
        guard status == 0 else { throw PasteboardError.simctlFailed(status: status) }
    }

    /// Run `xcrun` with `stdin` as the child's input; resolve with the
    /// exit status. Only a failed spawn throws — a non-zero exit is the
    /// caller's to interpret, since one route's failure picks the next.
    private func write(_ arguments: [String], stdin: Data) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    stdin: stdin,
                    onBytes: { _ in },
                    onExit: { code in continuation.resume(returning: code) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func text() async throws -> String {
        try await capture(simctl(["pbpaste", udid]))
    }

    func syncFromHost() async throws {
        _ = try await capture(simctl(["pbsync", "host", udid]))
    }

    func syncToHost() async throws {
        _ = try await capture(simctl(["pbsync", udid, "host"]))
    }

    private func simctl(_ verb: [String]) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + verb
    }

    /// Run `xcrun` collecting stdout; resolve with the collected
    /// output on exit 0, throw `simctlFailed` otherwise.
    private func capture(_ arguments: [String]) async throws -> String {
        final class Collected: @unchecked Sendable {
            var data = Data()
            let lock = NSLock()
            func append(_ bytes: Data) {
                lock.lock(); data.append(bytes); lock.unlock()
            }
            func string() -> String {
                lock.lock(); defer { lock.unlock() }
                return String(decoding: data, as: UTF8.self)
            }
        }
        let collected = Collected()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    onBytes: { collected.append($0) },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume(returning: collected.string())
                        } else {
                            continuation.resume(throwing: PasteboardError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
