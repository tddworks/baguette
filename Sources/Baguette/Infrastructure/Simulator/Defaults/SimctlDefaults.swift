import Foundation

/// `Defaults` backed by two simctl children per operation:
///
/// 1. `xcrun simctl get_app_container <udid> <bundle> data|groups` — where
///    the preferences live, so no container path is ever guessed.
/// 2. `xcrun simctl spawn <udid> defaults export|write|delete <plist> …` —
///    the simulator's own `defaults` tool, which goes through its
///    `cfprefsd` and so can't race the daemon's cache the way a host-side
///    file edit would.
///
/// The orchestration (argv assembly via `PreferenceSuite` /
/// `PreferenceValue`, exit-code mapping, export parsing) is unit-covered
/// through `MockSubprocess`; only `HostSubprocess`'s real spawn is
/// integration-only.
final class SimctlDefaults: Defaults, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    private let subprocess: any Subprocess
    private let xcrun: URL
    private let answers: URL
    private let isRunning: @Sendable (Int32) -> Bool

    /// `answers` is where `DefaultsLookups.dylib` leaves each app's answer:
    /// the host's `/tmp`, which every simulator shares. `isRunning` tells
    /// whether the app that wrote one is still alive — a simulator's apps
    /// are ordinary host processes, so `kill(pid, 0)` can see them.
    init(
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        answers: URL = URL(fileURLWithPath: "/tmp"),
        isRunning: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.xcrun = xcrun
        self.answers = answers
        self.isRunning = isRunning
    }

    /// The answer file for one app on one simulator. Scoped by both, since
    /// every simulator shares the host's `/tmp`. The dylib builds the same
    /// name from `SIMULATOR_UDID` and its main bundle's identifier.
    static func answerFileName(udid: String, bundleID: String) -> String {
        "BaguetteLookups-\(udid)-\(bundleID).plist"
    }

    /// The answer is a file the app rewrites whole as it grows, so it is
    /// the app's *current* answer — but it outlives the app. One whose
    /// writer has quit is a former run's, and answers nothing.
    func lookups(of bundleID: String) async throws -> PreferenceLookups? {
        let file = answers.appendingPathComponent(Self.answerFileName(udid: udid, bundleID: bundleID))
        guard let data = try? Data(contentsOf: file),
              let lookups = PreferenceLookups(answer: data),
              isRunning(lookups.pid)
        else { return nil }
        return lookups
    }

    func read(_ suite: PreferenceSuite) async throws -> Preferences {
        let output = try await defaults(["export", plist(of: suite), "-"])
        guard let preferences = Preferences(export: output) else {
            throw DefaultsError.unreadableDomain
        }
        return preferences
    }

    func write(_ value: PreferenceValue, forKey key: String, in suite: PreferenceSuite) async throws {
        _ = try await defaults(["write", plist(of: suite), key, value.xmlFragment])
    }

    func delete(key: String, in suite: PreferenceSuite) async throws {
        _ = try await defaults(["delete", plist(of: suite), key])
    }

    func groups(of bundleID: String) async throws -> [String] {
        let (status, output) = try await capture(
            ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["get_app_container", udid, bundleID, "groups"])
        switch status {
        case 0: return PreferenceSuite.groups(inListing: String(decoding: output, as: UTF8.self))
        case 2: throw DefaultsError.appNotInstalled(bundleID: bundleID)
        default: throw Self.failure(status)
        }
    }

    // MARK: - the two children

    /// The preferences plist inside the container simctl reports. Exit
    /// codes measured against Xcode 27: 2 = no such app, 149 = shut down.
    /// A suite missing from the app's group listing is `groupNotFound`.
    private func plist(of suite: PreferenceSuite) async throws -> String {
        let (status, output) = try await capture(suite.containerArguments(udid: udid, deviceSetPath: deviceSetPath))
        switch status {
        case 0: break
        case 2: throw DefaultsError.appNotInstalled(bundleID: suite.bundleID)
        default: throw Self.failure(status)
        }
        guard let plist = suite.plistPath(inContainerOutput: String(decoding: output, as: UTF8.self)) else {
            if let group = suite.group {
                throw DefaultsError.groupNotFound(group: group, bundleID: suite.bundleID)
            }
            throw DefaultsError.simctlFailed(status: status)
        }
        return plist
    }

    private func defaults(_ arguments: [String]) async throws -> Data {
        let (status, output) = try await capture(
            ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["spawn", udid, "defaults"] + arguments)
        guard status == 0 else { throw Self.failure(status) }
        return output
    }

    private static func failure(_ status: Int32) -> DefaultsError {
        status == 149 ? .deviceNotBooted : .simctlFailed(status: status)
    }

    /// Accumulates a child's output across chunks that may land on any queue.
    private final class ByteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            bytes.append(chunk)
        }

        func collected() -> Data {
            lock.lock(); defer { lock.unlock() }
            return bytes
        }
    }

    /// Run `xcrun <arguments>` to completion; hand back its exit status and
    /// everything it wrote, parsed once at exit rather than per chunk.
    private func capture(_ arguments: [String]) async throws -> (Int32, Data) {
        let buffer = ByteBox()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int32, Data), Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    onBytes: { buffer.append($0) },
                    onExit: { continuation.resume(returning: ($0, buffer.collected())) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
