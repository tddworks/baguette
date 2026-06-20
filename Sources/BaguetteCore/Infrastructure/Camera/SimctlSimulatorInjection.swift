import Foundation

/// `SimulatorInjection` backed by `xcrun simctl spawn <udid> launchctl …`.
///
/// `arm`   → `launchctl setenv DYLD_INSERT_LIBRARIES <dylibPath>`
/// `disarm`→ `launchctl unsetenv DYLD_INSERT_LIBRARIES`
///
/// Both are scoped to the simulator's launchd domain, so the env var
/// survives until the simulator reboots. Re-arming on every boot is
/// the caller's responsibility (the camera WS handler does that).
///
/// The orchestration here is pure: argv assembly + `Subprocess` exit
/// handshake. The `Foundation.Process` plumbing is inside
/// `HostSubprocess` (already vendored for `LogStream`), so this file
/// is unit-covered end-to-end via `MockSubprocess`.
final class SimctlSimulatorInjection: SimulatorInjection, @unchecked Sendable {
    private let subprocess: any Subprocess
    private let xcrun: URL

    init(
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.subprocess = subprocess
        self.xcrun = xcrun
    }

    func arm(dylibPath: String, on simulator: any Simulator) async throws {
        try await spawn(arguments: [
            "simctl", "spawn", simulator.udid,
            "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", dylibPath,
        ])
    }

    func disarm(on simulator: any Simulator) async throws {
        try await spawn(arguments: [
            "simctl", "spawn", simulator.udid,
            "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES",
        ])
    }

    private func spawn(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    onBytes: { _ in },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: SimulatorInjectionError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum SimulatorInjectionError: Error, Equatable, CustomStringConvertible {
    case simctlFailed(status: Int32)

    var description: String {
        switch self {
        case .simctlFailed(let status):
            return "xcrun simctl exited \(status) while arming/disarming the virtual camera dylib"
        }
    }
}
