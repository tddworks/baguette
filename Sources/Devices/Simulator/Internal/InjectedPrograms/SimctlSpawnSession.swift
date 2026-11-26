import BaguetteDevice
import Foundation

/// One serving program kept running inside the guest
/// (`xcrun simctl spawn <udid> <program> --deadline <t> serve`), fed one
/// command per line: `DeviceHubControls serve`, `HIDButtons serve`.
///
/// Kept rather than spawned per command: a spawn is most of a second, and the
/// program's HID service stays registered between commands. Commands are
/// played one at a time; one asked during a sweep queues behind it.
///
/// The program answers each command with `done <status>` once played, so a
/// call returns when the guest has acted and a one-shot CLI cannot exit with
/// its command still queued. A command not answered within the allowance
/// stops the program: its guest process is killed by the pid it printed at
/// startup, and a program that had not started refuses to act past its
/// `--deadline`. A timeout therefore means the command was delivered before
/// the deadline or never will be.
///
/// The orchestration — program lookup, argv, the write, the answer, stopping
/// and restarting the program — is unit-covered through `MockSubprocess`;
/// `HostSubprocess` is integration-only.
final class SimctlSpawnSession: @unchecked Sendable {
    private let program: String
    private let udid: String
    private let deviceSetPath: String?
    private let subprocess: () -> any Subprocess
    private let path: () -> String?
    private let xcrun: URL
    private let startTimeout: TimeInterval
    private let now: () -> Date
    private let stopGuest: (Int32) -> Void
    private let lock = NSLock()
    private let commands = NSLock()
    private var child: Child?

    /// How long past the program's deadline the host keeps waiting, so the
    /// pid of a program that started just before it has arrived.
    static let answerGrace: TimeInterval = 1

    /// A program's exit status when it started after its deadline.
    private static let startedLateStatus: Int32 = 3

    /// One session, one serving child, per device and program, however many
    /// displays, hinges and inputs ask for it.
    private struct Key: Hashable {
        let program: String
        let deviceSetPath: String?
        let udid: String
    }
    nonisolated(unsafe) private static var registry: [Key: SimctlSpawnSession] = [:]
    private static let registryLock = NSLock()

    static func forDevice(
        _ udid: String, deviceSetPath: String? = nil, program: String, path: @escaping () -> String?
    ) -> SimctlSpawnSession {
        let key = Key(program: program, deviceSetPath: deviceSetPath, udid: udid)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let made = SimctlSpawnSession(program: program, udid: udid, deviceSetPath: deviceSetPath, path: path)
        registry[key] = made
        return made
    }

    /// `startTimeout` bounds a program's start and each command beyond its
    /// own playing time; `stopGuest` kills a guest process by pid.
    init(
        program: String,
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: @escaping () -> any Subprocess = { HostSubprocess() },
        path: @escaping () -> String?,
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        startTimeout: TimeInterval = 8,
        now: @escaping () -> Date = { Date() },
        stopGuest: @escaping (Int32) -> Void = { _ = Darwin.kill($0, SIGKILL) }
    ) {
        self.program = program
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.path = path
        self.xcrun = xcrun
        self.startTimeout = startTimeout
        self.now = now
        self.stopGuest = stopGuest
    }

    /// One command to the serving child, started if need be; returns once
    /// the child has answered it. `duration` is how long it plays.
    func send(_ line: String, playing duration: TimeInterval) throws {
        commands.lock()
        defer { commands.unlock() }
        let child = try serving()
        do {
            try child.process.write(Data((line + "\n").utf8))
        } catch {
            abandon(child)
            throw error
        }
        switch child.answer(within: duration + startTimeout + Self.answerGrace) {
        case .done(0):
            return
        case .exited(Self.startedLateStatus):
            throw InjectedProgramError.startedLate(program: program)
        case .done(let status), .exited(let status):
            throw InjectedProgramError.failed(program: program, status: status)
        case .silent:
            abandon(child)
            throw InjectedProgramError.timedOut(program: program)
        }
    }

    /// Whole numbers print without a fraction, for a line that reads well.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private var spawnArguments: [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["spawn", udid]
    }

    private func serving() throws -> Child {
        lock.lock()
        defer { lock.unlock() }
        if let child { return child }
        guard let path = path() else { throw InjectedProgramError.missing(program: program) }
        let started = Child(process: subprocess())
        let deadline = now().timeIntervalSince1970 + startTimeout
        try started.process.runInteractive(
            executable: xcrun,
            arguments: spawnArguments + [path, "--deadline", Self.number(deadline), "serve"],
            onBytes: { [weak started] in started?.receive($0) },
            onExit: { [weak self, weak started] status in
                started?.exited(status)
                guard let self, let started else { return }
                self.lock.lock()
                if self.child === started { self.child = nil }
                self.lock.unlock()
            }
        )
        child = started
        return started
    }

    /// Stop a child that stopped answering, guest process first.
    private func abandon(_ child: Child) {
        if let pid = child.pid { stopGuest(pid) }
        child.process.kill()
        lock.lock()
        if self.child === child { self.child = nil }
        lock.unlock()
    }

    /// One serving child, its guest pid and the answers it has given.
    private final class Child: @unchecked Sendable {
        enum Answer: Equatable {
            case done(Int32)
            case exited(Int32)
            case silent
        }

        let process: any Subprocess
        private let lock = NSLock()
        private let arrived = DispatchSemaphore(value: 0)
        private var replies = InjectedProgramReplyReader()
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

        /// The next answer, the exit that ended the child first, or `.silent`
        /// when neither came within `seconds`.
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

/// Why a program baguette runs in the guest did not do what it was asked.
enum InjectedProgramError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The build did not ship the program, or it could not be installed.
    case missing(program: String)
    case failed(program: String, status: Int32)
    /// It did not answer in time and was stopped.
    case timedOut(program: String)
    /// It started after its deadline and did nothing.
    case startedLate(program: String)

    var description: String {
        switch self {
        case .missing(let program): "\(program) is missing or could not be installed."
        case .failed(let program, let status): "\(program) exited with status \(status)."
        case .timedOut(let program): "\(program) did not answer in time; the command may have been delivered, but the stopped program cannot deliver it later."
        case .startedLate(let program): "\(program) started after its deadline and did nothing; the command was not delivered."
        }
    }

    var errorDescription: String? { description }
}
