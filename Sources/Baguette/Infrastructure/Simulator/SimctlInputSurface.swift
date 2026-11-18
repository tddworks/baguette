import Foundation

/// `InputSurface` backed by `xcrun simctl spawn <udid> …` into the guest.
///
/// Detection is one read of the notify state Device Hub's daemon sets:
///
/// ```
/// notifyutil -g com.apple.coredevice.dtuhidd.active   → "<key> 1" when attached
/// ```
///
/// `ready` is `simctl bootstatus <udid> -b` — the host-side wait for a
/// boot to actually finish, which `baguette boot` needs before asking —
/// plus, when Device Hub is running, a bounded wait for its daemon's
/// state to show up (it lands a beat after `bootstatus` on a warm boot).
///
/// Reclaiming is a fixed three-step conversation with the guest:
///
/// ```
/// launchctl list                                        → remember SpringBoard's pid
/// notifyutil -s com.apple.coredevice.dtuhidd.active 0  → SimulatorHID will read "absent"
/// launchctl kickstart -k system/com.apple.backboardd   → restart; SpringBoard follows
/// launchctl list … (poll)                               → until SpringBoard has a new pid
/// ```
///
/// Order matters: the state is cleared *before* the restart so the new
/// backboardd initialises with every legacy service connected and never
/// sees the active→inactive edge that (on iOS 27) leaves services dead.
/// Device Hub's daemon only re-publishes `1` when it itself restarts, so
/// the repair holds until the user relaunches Device Hub — at which point
/// `shadowed` reads true again and the advisory reappears.
///
/// The orchestration here — argv, the exit handshake, the pid-change
/// poll — is unit-covered via `MockSubprocess`; `Foundation.Process`
/// plumbing lives in `HostSubprocess`.
final class SimctlInputSurface: InputSurface, @unchecked Sendable {
    typealias Sleep = @Sendable (Duration) async -> Void

    /// The one simulator whose surface this reads and repairs.
    private let simulator: any Simulator
    private let subprocess: any Subprocess
    private let xcrun: URL
    private let deviceHubRunning: @Sendable () -> Bool
    private let sleep: Sleep

    private static let springBoard = "com.apple.SpringBoard"
    private static let backboardd = "system/com.apple.backboardd"
    /// SpringBoard is usually back within ~4 s; anything past this is a
    /// device that isn't coming back on its own.
    private static let pollInterval: Duration = .milliseconds(500)
    private static let pollAttempts = 60
    /// A freshly launched SpringBoard has a pid before it has a home
    /// screen; give it a moment before the caller's first tap.
    private static let settle: Duration = .seconds(2)

    /// Device Hub's daemon publishes its state a beat *after*
    /// `bootstatus` returns on a warm boot; with Device Hub up on the
    /// host the attach is coming, so `ready` waits this long for it.
    private static let attachAttempts = 20

    /// - Parameter deviceHubRunning: whether Device Hub is running on the
    ///   host right now. Defaults to asking the workspace for its bundle;
    ///   tests inject the answer.
    init(
        simulator: any Simulator,
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        deviceHubRunning: @escaping @Sendable () -> Bool = { DeviceHubApp.isRunning },
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }
    ) {
        self.simulator = simulator
        self.subprocess = subprocess
        self.xcrun = xcrun
        self.deviceHubRunning = deviceHubRunning
        self.sleep = sleep
    }

    func shadowed() async -> Bool {
        let state = try? await spawn(on: simulator, [
            "notifyutil", "-g", DeviceHubAttachment.stateKey,
        ])
        return DeviceHubAttachment.parsing(state).attached
    }

    func ready() async throws {
        // Not a guest spawn: `bootstatus -b` is the host-side verb that
        // blocks until the device has finished booting. SpringBoard and
        // backboardd have pids within a second of `boot()` returning, and
        // Device Hub's daemon publishes its state a second after that —
        // a pid poll would answer long before the surface is settled.
        try await run(simctl(on: simulator, ["bootstatus", simulator.udid, "-b"]))
        // Only worth waiting for when there is a Device Hub to attach;
        // a headless host would just pay the full timeout every boot.
        guard deviceHubRunning() else { return }
        for attempt in 0..<Self.attachAttempts {
            if attempt > 0 { await sleep(Self.pollInterval) }
            if await shadowed() { return }
        }
    }

    func reclaim() async throws {
        let before = await springBoardPid(on: simulator)
        try await spawn(on: simulator, ["notifyutil", "-s", DeviceHubAttachment.stateKey, "0"])
        try await spawn(on: simulator, ["launchctl", "kickstart", "-k", Self.backboardd])
        // `before` is nil only if SpringBoard was already gone; any pid
        // then counts as "back".
        await sleep(Self.pollInterval)
        _ = try await awaitSpringBoard(on: simulator, otherThan: before, attempts: Self.pollAttempts)
        await sleep(Self.settle)
    }

    /// Poll `launchctl list` until SpringBoard is running under a pid
    /// other than `otherThan`, sleeping between misses.
    private func awaitSpringBoard(
        on simulator: any Simulator, otherThan old: Int32?, attempts: Int
    ) async throws -> Int32 {
        for attempt in 0..<attempts {
            if attempt > 0 { await sleep(Self.pollInterval) }
            if let now = await springBoardPid(on: simulator), now != old { return now }
        }
        throw InputSurfaceError.springBoardMissing
    }

    private func springBoardPid(on simulator: any Simulator) async -> Int32? {
        let listing = try? await spawn(on: simulator, ["launchctl", "list"])
        return LaunchdJobs.parsing(listing).pid(of: Self.springBoard)
    }

    /// Runs one command inside the simulator, returning its stdout.
    @discardableResult
    private func spawn(on simulator: any Simulator, _ command: [String]) async throws -> String {
        try await run(simctl(on: simulator, ["spawn", simulator.udid] + command))
    }

    /// `xcrun simctl` argv addressed to the device set `simulator` lives in.
    private func simctl(on simulator: any Simulator, _ verb: [String]) -> [String] {
        ["simctl"] + (simulator.deviceSetPath.map { ["--set", $0] } ?? []) + verb
    }

    /// Runs one `xcrun` invocation, returning its stdout.
    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        final class Output: @unchecked Sendable {
            var data = Data()
        }
        let output = Output()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    onBytes: { output.data.append($0) },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume(
                                returning: String(decoding: output.data, as: UTF8.self))
                        } else {
                            continuation.resume(
                                throwing: InputSurfaceError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
