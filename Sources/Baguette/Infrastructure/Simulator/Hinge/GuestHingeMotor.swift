import Foundation

/// `HingeMotor` — and `DeviceKeys` — that keeps `HingeControl serve`
/// running inside the guest (`xcrun simctl spawn <udid> <HingeControl>
/// --deadline <t> serve`) and writes each command to it: `sweep <from>
/// <to> <ms>`, `orientation <native-value>`, `button <page> <usage> <ms>`.
///
/// The tool registers a HID service shaped like dtuhidd's `avpCustom`
/// and dispatches the pose events Device Hub sends (see
/// `Injected/HingeControl/Sources/HingeControl.m`); the runtime folds,
/// SpringBoard swaps panels, and `GuestHinge` reads the sweep back
/// like any other. Kept rather than spawned per command: a spawn is most
/// of a second, and the service stays registered between poses. Commands
/// are played one at a time — a pick during a sweep queues behind it.
///
/// The tool answers each command with `done <status>` once played, so a
/// call returns when the guest has acted and a one-shot CLI cannot exit
/// with its command still queued. A command not answered within the
/// allowance stops the tool: its guest process is killed by the pid it
/// printed at startup, and a tool that had not started refuses to act past
/// its `--deadline`. A timeout therefore means the command was delivered
/// before the deadline or never will be.
///
/// The orchestration — tool lookup, argv, the write, the answer, stopping
/// and restarting the tool — is unit-covered through `MockSubprocess`;
/// `HostSubprocess` is integration-only.
final class GuestHingeMotor: HingeMotor, DeviceKeys, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    private let subprocess: () -> any Subprocess
    private let tool: () -> String?
    private let xcrun: URL
    private let helperTimeout: TimeInterval
    private let now: () -> Date
    private let stopGuest: (Int32) -> Void
    private let lock = NSLock()
    private let commands = NSLock()
    private var helper: Helper?

    /// How long past the helper's deadline the host keeps waiting, so the
    /// pid of a helper that started just before it has arrived.
    static let answerGrace: TimeInterval = 1

    /// `HingeControl`'s exit status when it started after its deadline.
    private static let startedLateStatus: Int32 = 3

    /// One motor — one serving child — per device, however many
    /// displays and hinges ask for it.
    private struct DeviceKey: Hashable {
        let deviceSetPath: String?
        let udid: String
    }
    nonisolated(unsafe) private static var registry: [DeviceKey: GuestHingeMotor] = [:]
    private static let registryLock = NSLock()

    static func forDevice(_ udid: String, deviceSetPath: String? = nil) -> GuestHingeMotor {
        let key = DeviceKey(deviceSetPath: deviceSetPath, udid: udid)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let made = GuestHingeMotor(udid: udid, deviceSetPath: deviceSetPath)
        registry[key] = made
        return made
    }

    /// `helperTimeout` bounds a tool's start and each command beyond its
    /// own playing time; `stopGuest` kills a guest process by pid.
    init(
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: @escaping () -> any Subprocess = { HostSubprocess() },
        tool: @escaping () -> String? = { InjectedDylibInstaller.installIfNeeded(.hingeControl) },
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        helperTimeout: TimeInterval = 8,
        now: @escaping () -> Date = { Date() },
        stopGuest: @escaping (Int32) -> Void = { _ = Darwin.kill($0, SIGKILL) }
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.tool = tool
        self.xcrun = xcrun
        self.helperTimeout = helperTimeout
        self.now = now
        self.stopGuest = stopGuest
    }

    func fold(from: Double, to: Double, over duration: TimeInterval) throws {
        try send("sweep \(Self.number(from)) \(Self.number(to)) \(Self.number(duration * 1000))", playing: duration)
    }

    /// Modifiers ride the same line as trailing `<page> <usage>` pairs.
    func press(_ usage: HIDUsage, holding modifiers: [HIDUsage], hold: TimeInterval) throws {
        let held = modifiers.map { " \($0.page) \($0.usage)" }.joined()
        try send("button \(usage.page) \(usage.usage) \(Self.number(hold * 1000))\(held)", playing: hold)
    }

    func turn(to orientation: DeviceOrientation) throws {
        let name: String
        // Native landscape labels are opposite the public home-button convention.
        switch orientation {
        case .portrait: name = "portrait"
        case .portraitUpsideDown: name = "pud"
        case .landscapeLeft: name = "landscape-right"
        case .landscapeRight: name = "landscape-left"
        }
        try send("orientation \(name)", playing: 0)
    }

    private var spawnArguments: [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["spawn", udid]
    }

    /// One command to the serving child, started if need be; returns once
    /// the child has answered it.
    private func send(_ line: String, playing duration: TimeInterval) throws {
        commands.lock()
        defer { commands.unlock() }
        let helper = try serving()
        do {
            try helper.process.write(Data((line + "\n").utf8))
        } catch {
            abandon(helper)
            throw error
        }
        switch helper.answer(within: duration + helperTimeout + Self.answerGrace) {
        case .done(0):
            return
        case .exited(Self.startedLateStatus):
            throw HingeError.toolStartedLate
        case .done(let status), .exited(let status):
            throw HingeError.toolFailed(status: status)
        case .silent:
            abandon(helper)
            throw HingeError.toolTimedOut
        }
    }

    private func serving() throws -> Helper {
        lock.lock()
        defer { lock.unlock() }
        if let helper { return helper }
        guard let tool = tool() else { throw HingeError.toolMissing }
        let started = Helper(process: subprocess())
        let deadline = now().timeIntervalSince1970 + helperTimeout
        try started.process.runInteractive(
            executable: xcrun,
            arguments: spawnArguments + [tool, "--deadline", Self.number(deadline), "serve"],
            onBytes: { [weak started] in started?.receive($0) },
            onExit: { [weak self, weak started] status in
                started?.exited(status)
                guard let self, let started else { return }
                self.lock.lock()
                if self.helper === started { self.helper = nil }
                self.lock.unlock()
            }
        )
        helper = started
        return started
    }

    /// Stop a child that stopped answering, guest process first.
    private func abandon(_ helper: Helper) {
        if let pid = helper.pid { stopGuest(pid) }
        helper.process.kill()
        lock.lock()
        if self.helper === helper { self.helper = nil }
        lock.unlock()
    }

    /// Whole numbers print without a fraction, for a line that reads well.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// One serving child, its guest pid and the answers it has given.
    private final class Helper: @unchecked Sendable {
        enum Answer: Equatable {
            case done(Int32)
            case exited(Int32)
            case silent
        }

        let process: any Subprocess
        private let lock = NSLock()
        private let arrived = DispatchSemaphore(value: 0)
        private var replies = HingeControlReplyReader()
        private var answers: [Int32] = []
        private var exitStatus: Int32?
        private var guestPID: Int32?

        init(process: any Subprocess) {
            self.process = process
        }

        var pid: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return guestPID
        }

        func receive(_ bytes: Data) {
            lock.lock()
            var count = 0
            for reply in replies.append(bytes) {
                switch reply {
                case .pid(let pid): guestPID = pid
                case .done(let status): answers.append(status); count += 1
                }
            }
            lock.unlock()
            for _ in 0..<count { arrived.signal() }
        }

        func exited(_ status: Int32) {
            lock.lock()
            exitStatus = status
            lock.unlock()
            arrived.signal()
        }

        /// The next answer, the exit that ended the child first, or
        /// `.silent` when neither came within `seconds`.
        func answer(within seconds: TimeInterval) -> Answer {
            let deadline = DispatchTime.now() + seconds
            while true {
                lock.lock()
                if !answers.isEmpty {
                    let status = answers.removeFirst()
                    lock.unlock()
                    return .done(status)
                }
                if let exitStatus {
                    lock.unlock()
                    return .exited(exitStatus)
                }
                lock.unlock()
                if arrived.wait(timeout: deadline) == .timedOut {
                    lock.lock()
                    defer { lock.unlock() }
                    if !answers.isEmpty { return .done(answers.removeFirst()) }
                    return exitStatus.map { .exited($0) } ?? .silent
                }
            }
        }
    }
}
