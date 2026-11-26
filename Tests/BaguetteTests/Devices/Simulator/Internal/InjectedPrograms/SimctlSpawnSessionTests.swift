import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// A serving program (`DeviceHubControls serve`, `HIDButtons serve`) is
/// spawned once in the guest with `simctl spawn` and kept, playing every
/// command it is written on stdin, so a command costs no spawn. The session's
/// job is that child: start it on the first command, write each command and
/// wait for its answer, stop it when it does not answer, and start it again if
/// it went away.
@Suite("SimctlSpawnSession")
struct SimctlSpawnSessionTests {

    /// A scripted program: what it prints when started and in answer to each
    /// command it is written.
    final class Guest: @unchecked Sendable {
        var runs: [[String]] = []
        var executable: URL?
        var written: [String] = []
        var killed = 0
        var stopped: [Int32] = []
        var greeting: String? = "pid 4242\n"
        var answer: (String) -> [String] = { _ in ["done 0\n"] }
        var exitOnWrite: Int32?
        var onBytes: (@Sendable (Data) -> Void)?
        var onExit: (@Sendable (Int32) -> Void)?
    }

    struct SpawnFailed: Error, Equatable {}

    /// A session over a scripted guest, for any program.
    static func make(
        program: String = "DeviceHubControls", deviceSetPath: String? = nil,
        path: String? = "/tmp/builds/abc/DeviceHubControls", spawnFails: Bool = false
    ) -> (SimctlSpawnSession, Guest) {
        let sub = MockSubprocess()
        let guest = Guest()
        given(sub).runInteractive(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { exe, args, onBytes, onExit in
                if spawnFails { throw SpawnFailed() }
                guest.executable = exe
                guest.runs.append(args)
                guest.onBytes = onBytes
                guest.onExit = onExit
                if let greeting = guest.greeting { onBytes(Data(greeting.utf8)) }
            }
        given(sub).write(.any).willProduce { data in
            let line = String(decoding: data, as: UTF8.self)
            guest.written.append(line)
            for chunk in guest.answer(line) { guest.onBytes?(Data(chunk.utf8)) }
            if let status = guest.exitOnWrite { guest.onExit?(status) }
        }
        given(sub).kill().willProduce { guest.killed += 1 }
        given(sub).terminate().willReturn()
        let session = SimctlSpawnSession(
            program: program, udid: "duo", deviceSetPath: deviceSetPath, subprocess: { sub }, path: { path },
            startTimeout: 0.05, now: { Date(timeIntervalSince1970: 1000) },
            stopGuest: { guest.stopped.append($0) })
        return (session, guest)
    }

    @Test func `should start the program serving under a deadline on the first command and write later ones to it`() throws {
        let (session, guest) = Self.make()
        try session.send("sweep 130 0 800", playing: 0.8)
        try session.send("sweep 0 180 500", playing: 0.5)
        #expect(guest.executable?.path == "/usr/bin/xcrun")
        #expect(guest.runs == [["simctl", "spawn", "duo", "/tmp/builds/abc/DeviceHubControls", "--deadline", "1000.05", "serve"]])
        #expect(guest.written == ["sweep 130 0 800\n", "sweep 0 180 500\n"])
    }

    @Test func `should spawn the program inside a custom device set`() throws {
        let (session, guest) = Self.make(deviceSetPath: "/tmp/custom devices")
        try session.send("orientation portrait", playing: 0)
        #expect(guest.runs == [
            ["simctl", "--set", "/tmp/custom devices", "spawn", "duo", "/tmp/builds/abc/DeviceHubControls", "--deadline", "1000.05", "serve"],
        ])
    }

    @Test func `should keep one session per program, device set and device`() {
        let udid = UUID().uuidString
        let path: () -> String? = { nil }
        let a = SimctlSpawnSession.forDevice(udid, deviceSetPath: "/sets/a", program: "DeviceHubControls", path: path)
        #expect(a === SimctlSpawnSession.forDevice(udid, deviceSetPath: "/sets/a", program: "DeviceHubControls", path: path))
        #expect(a !== SimctlSpawnSession.forDevice(udid, deviceSetPath: "/sets/a", program: "HIDButtons", path: path))
        #expect(a !== SimctlSpawnSession.forDevice(udid, deviceSetPath: "/sets/b", program: "DeviceHubControls", path: path))
        #expect(a !== SimctlSpawnSession.forDevice(udid, program: "DeviceHubControls", path: path))
        #expect(a !== SimctlSpawnSession.forDevice(UUID().uuidString, deviceSetPath: "/sets/a", program: "DeviceHubControls", path: path))
    }

    @Test func `should fail with the program's status when it refuses a command`() {
        let (session, guest) = Self.make()
        guest.answer = { _ in ["done 2\n"] }
        #expect(throws: InjectedProgramError.failed(program: "DeviceHubControls", status: 2)) {
            try session.send("bogus", playing: 0)
        }
    }

    @Test func `should understand answers split across reads and mixed with diagnostics`() throws {
        let (session, guest) = Self.make()
        guest.greeting = "runtime warning\npi"
        guest.answer = { _ in ["d 4242\nbad line: x\ndo", "ne 0\n"] }
        try session.send("orientation landscape-right", playing: 0)
    }

    @Test func `should stop the program and time out when a command is not answered`() throws {
        let (session, guest) = Self.make()
        guest.answer = { _ in [] }
        #expect(throws: InjectedProgramError.timedOut(program: "DeviceHubControls")) {
            try session.send("orientation portrait", playing: 0)
        }
        #expect(guest.stopped == [4242])
        #expect(guest.killed == 1)
        guest.answer = { _ in ["done 0\n"] }
        try session.send("orientation portrait", playing: 0)
        #expect(guest.runs.count == 2)
    }

    @Test func `should still abandon an unanswering program when it never announced its pid`() {
        let (session, guest) = Self.make()
        guest.greeting = nil
        guest.answer = { _ in [] }
        #expect(throws: InjectedProgramError.timedOut(program: "DeviceHubControls")) {
            try session.send("sweep 0 130 0", playing: 0)
        }
        #expect(guest.stopped.isEmpty)
        #expect(guest.killed == 1)
    }

    @Test func `should fail when the program ends without answering, and start another for the next command`() throws {
        let (session, guest) = Self.make()
        guest.answer = { _ in [] }
        guest.exitOnWrite = 164
        #expect(throws: InjectedProgramError.failed(program: "DeviceHubControls", status: 164)) {
            try session.send("sweep 0 130 500", playing: 0.5)
        }
        guest.answer = { _ in ["done 0\n"] }
        guest.exitOnWrite = nil
        try session.send("sweep 130 0 500", playing: 0.5)
        #expect(guest.runs.count == 2)
    }

    /// Under load a spawn can outlast the program's deadline; it then exits
    /// 3 having done nothing, which is a definite failure, not a timeout.
    @Test func `should report nothing was delivered when the program started after its deadline`() {
        let (session, guest) = Self.make()
        guest.answer = { _ in [] }
        guest.exitOnWrite = 3
        #expect(throws: InjectedProgramError.startedLate(program: "DeviceHubControls")) {
            try session.send("orientation pud", playing: 0)
        }
    }

    @Test func `should name the program in what it says went wrong`() {
        #expect(String(describing: InjectedProgramError.startedLate(program: "HIDButtons"))
            == "HIDButtons started after its deadline and did nothing; the command was not delivered.")
        #expect(String(describing: InjectedProgramError.timedOut(program: "HIDButtons"))
            == "HIDButtons did not answer in time; the command may have been delivered, but the stopped program cannot deliver it later.")
        #expect(String(describing: InjectedProgramError.missing(program: "HIDButtons"))
            == "HIDButtons is missing or could not be installed.")
    }

    @Test func `should start the program again for the next command when it went away`() throws {
        let (session, guest) = Self.make()
        try session.send("sweep 0 130 800", playing: 0.8)
        guest.onExit?(0)
        try session.send("sweep 130 0 800", playing: 0.8)
        #expect(guest.runs.count == 2)
    }

    @Test func `should fail when the program is missing or cannot be spawned`() {
        let (missing, _) = Self.make(path: nil)
        #expect(throws: InjectedProgramError.missing(program: "DeviceHubControls")) {
            try missing.send("sweep 0 130 500", playing: 0.5)
        }
        let (failing, _) = Self.make(spawnFails: true)
        #expect(throws: SpawnFailed()) { try failing.send("sweep 0 130 500", playing: 0.5) }
    }
}
