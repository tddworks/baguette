import Foundation

/// `Shake` backed by `xcrun simctl spawn <udid> notifyutil -p
/// com.apple.UIKit.SimulatorShake`.
///
/// The orchestration here is pure: argv assembly (delegated to
/// `MotionShake.simctlArguments(udid:)`) + the `Subprocess` exit
/// handshake. The `Foundation.Process` plumbing lives in
/// `HostSubprocess` (already vendored for `LogStream` / `SimctlLocation`),
/// so this file is unit-covered end-to-end via `MockSubprocess` — only
/// the real spawn is integration-only.
final class SimctlShake: Shake, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    private let signal: MotionShake
    private let subprocess: any Subprocess
    private let xcrun: URL

    init(
        udid: String,
        deviceSetPath: String? = nil,
        signal: MotionShake = MotionShake(),
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.signal = signal
        self.subprocess = subprocess
        self.xcrun = xcrun
    }

    func shake() async throws {
        try await spawn(signal.simctlArguments(udid: udid, deviceSetPath: deviceSetPath))
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
                            continuation.resume(throwing: ShakeError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
