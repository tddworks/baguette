import Foundation

/// `Location` backed by `xcrun simctl location <udid> set | start | clear`.
///
/// The orchestration here is pure: argv assembly (delegated to
/// `Coordinate.argument` / `LocationRoute.startArguments`) + the
/// `Subprocess` exit handshake. The `Foundation.Process` plumbing lives
/// in `HostSubprocess` (already vendored for `LogStream`), so this file
/// is unit-covered end-to-end via `MockSubprocess` — only the real spawn
/// is integration-only.
final class SimctlLocation: Location, @unchecked Sendable {
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

    func set(_ coordinate: Coordinate) async throws {
        try await spawn(arguments(["set", coordinate.argument]))
    }

    func start(_ route: LocationRoute) async throws {
        try await spawn(arguments(["start"] + route.startArguments))
    }

    func clear() async throws {
        try await spawn(arguments(["clear"]))
    }

    private func arguments(_ verb: [String]) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["location", udid] + verb
    }

    private func spawn(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    onBytes: { _ in },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: LocationError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
