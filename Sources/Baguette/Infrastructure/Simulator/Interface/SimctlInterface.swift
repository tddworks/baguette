import Foundation

/// `Interface` backed by `xcrun simctl ui <udid> <option> [<value>]`.
///
/// The orchestration here is pure: pick the verb, append the value when
/// there is one, and hand the exit code to the `Subprocess` handshake.
/// The `Foundation.Process` plumbing lives in `HostSubprocess` (already
/// vendored for `LogStream` and reused by `SimctlStatusBar`), so this
/// file is unit-covered end-to-end via `MockSubprocess` — only the real
/// spawn is integration-only.
///
/// One asymmetry worth knowing: reads are forgiving and writes are not.
/// `simctl ui` answers `unknown` with exit 0 for a device that isn't
/// booted, so a read returns that state; asking to *apply* `unknown` is
/// a caller mistake and is refused before anything is spawned.
final class SimctlInterface: Interface, @unchecked Sendable {
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

    // MARK: - reading

    func appearance() async throws -> InterfaceAppearance {
        InterfaceAppearance(output: try await capture(option: .appearance))
    }

    func increaseContrast() async throws -> InterfaceContrast {
        InterfaceContrast(output: try await capture(option: .increaseContrast))
    }

    func contentSize() async throws -> ContentSize {
        ContentSize(output: try await capture(option: .contentSize))
    }

    // MARK: - writing

    func setAppearance(_ appearance: InterfaceAppearance) async throws {
        guard let value = appearance.argument else {
            throw InterfaceError.notSettable(appearance.rawValue)
        }
        try await spawn(option: .appearance, value: value)
    }

    func setIncreaseContrast(_ contrast: InterfaceContrast) async throws {
        guard let value = contrast.argument else {
            throw InterfaceError.notSettable(contrast.rawValue)
        }
        try await spawn(option: .increaseContrast, value: value)
    }

    func setContentSize(_ change: ContentSizeChange) async throws {
        guard let value = change.argument else {
            throw InterfaceError.notSettable(change.wire)
        }
        try await spawn(option: .contentSize, value: value)
    }

    // MARK: - the simctl verbs

    /// The `simctl ui` option names. Spelled once so a read and its
    /// matching write can't drift apart.
    private enum Option: String {
        case appearance
        case increaseContrast = "increase_contrast"
        case contentSize = "content_size"
    }

    private func arguments(_ option: Option, _ value: String? = nil) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["ui", udid, option.rawValue] + (value.map { [$0] } ?? [])
    }

    // MARK: - the subprocess handshake

    /// Run a read, accumulate its stdout, and return it on a clean exit.
    /// `onBytes` may fire on a background queue, so the buffer is
    /// lock-guarded.
    private func capture(option: Option) async throws -> String {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
            var string: String {
                lock.lock(); defer { lock.unlock() }
                return String(decoding: data, as: UTF8.self)
            }
        }
        let box = Box()
        let argv = arguments(option)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: argv,
                    onBytes: { box.append($0) },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume(returning: box.string)
                        } else {
                            continuation.resume(throwing: InterfaceError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func spawn(option: Option, value: String) async throws {
        let argv = arguments(option, value)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: argv,
                    onBytes: { _ in },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: InterfaceError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
