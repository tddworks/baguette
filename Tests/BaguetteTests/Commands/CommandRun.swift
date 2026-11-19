import ArgumentParser
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// What one command run did: what it answered on stdout, what it told the
/// user on stderr, the bytes it wrote raw, and the exit status it ended
/// with (0 when `run()` returned).
struct CommandRun {
    let said: [String]
    let told: [String]
    let written: Data
    let exit: Int32
}

/// The kinds of device a test run reaches: no simulators, and `devices`
/// as the one family that answers.
func reaching(_ devices: any Devices, simulators: [any Simulator] = []) -> DeviceKinds {
    let host = MockSimulators()
    given(host).all.willReturn(simulators)
    given(host).find(udid: .any).willProduce { udid in simulators.first { $0.udid == udid } }
    return DeviceKinds(simulators: host, phones: devices, androids: AndroidDevices(adb: nil))
}

/// No device at all: every `--udid` names nothing.
func noDevices() -> any Devices {
    let devices = MockDevices()
    given(devices).all.willReturn([])
    given(devices).find(id: .any).willReturn(nil)
    return devices
}

/// Run `command` reaching `devices`, its words and exit captured.
func run(
    _ command: some AsyncParsableCommand, on devices: any Devices = noDevices(),
    terminal: Terminal = .silent
) async throws -> CommandRun {
    try await run(reaching: reaching(devices), terminal: terminal) { var command = command; try await command.run() }
}

/// Run `command` reaching `devices`, its words and exit captured.
func run(
    _ command: some ParsableCommand, on devices: any Devices = noDevices(),
    terminal: Terminal = .silent
) async throws -> CommandRun {
    try await run(reaching: reaching(devices), terminal: terminal) { var command = command; try command.run() }
}

/// Run `body` as a command reaching `kinds`, its words and exit captured.
/// Any error but an exit status passes through.
func run(
    reaching kinds: DeviceKinds, terminal: Terminal = .silent,
    _ body: () async throws -> Void
) async throws -> CommandRun {
    let said = Lines(), told = Lines(), written = Bytes()
    let output = CommandOutput(say: said.add, warn: told.add, write: written.add)
    var status: Int32 = 0
    do {
        try await DeviceOption.$reachable.withValue(kinds) {
            try await CommandOutput.$current.withValue(output) {
                try await Terminal.$current.withValue(terminal) {
                    try await body()
                }
            }
        }
    } catch let exit as ExitCode {
        status = exit.rawValue
    }
    return CommandRun(said: said.all, told: told.all, written: written.all, exit: status)
}

/// Bytes a command wrote, in order.
final class Bytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var all: Data { lock.withLock { data } }

    @Sendable func add(_ chunk: Data) { lock.withLock { data.append(chunk) } }
}

extension Terminal {
    /// A terminal with nothing piped in that is never interrupted.
    static let silent = Terminal(lines: [])

    /// A terminal with `lines` piped in, interrupted at once when
    /// `interrupted` — the Ctrl-C a long run waits for.
    init(lines: [String], interrupted: Bool = false) {
        let queue = Lines()
        lines.forEach(queue.add)
        let next = Cursor()
        self.init(
            readLine: { next.take(from: queue.all) },
            readAll: { Data(queue.all.joined(separator: "\n").utf8) },
            onInterrupt: { _, handler in
                if interrupted { handler() }
                return {}
            }
        )
    }
}

/// How far a test terminal's stdin has been read.
final class Cursor: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func take(from lines: [String]) -> String? {
        lock.withLock {
            guard index < lines.count else { return nil }
            defer { index += 1 }
            return lines[index]
        }
    }
}
