import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// The hinge is moved from inside the guest: `HingeControl serve`, spawned
/// once with `simctl spawn` and kept, registers a HID service shaped like
/// dtuhidd's and plays every command it is written on stdin — so a pose
/// change costs no spawn. The motor's job is that child: start it on the
/// first command, write each command to it and wait for its answer, stop
/// it when it does not answer, and start it again if it went away.
@Suite("GuestHingeMotor")
struct GuestHingeMotorTests {

    /// A scripted helper: what it prints when started and in answer to
    /// each command it is written.
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

    private func make(deviceSetPath: String? = nil, tool: String? = "/tmp/builds/abc/HingeControl", spawnFails: Bool = false)
        -> (GuestHingeMotor, Guest) {
        let sub = MockSubprocess()
        let guest = Guest()
        given(sub).runInteractive(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { exe, args, onBytes, onExit in
                if spawnFails { throw HingeError.toolFailed(status: 1) }
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
        let motor = GuestHingeMotor(
            udid: "duo", deviceSetPath: deviceSetPath, subprocess: { sub }, tool: { tool },
            helperTimeout: 0.05, now: { Date(timeIntervalSince1970: 1000) },
            stopGuest: { guest.stopped.append($0) })
        return (motor, guest)
    }

    @Test func `should start the guest tool serving under a deadline on the first command and write later ones to it`() throws {
        let (motor, guest) = make()
        try motor.fold(from: 130, to: 0, over: 0.8)
        try motor.fold(from: 0, to: 180, over: 0.5)
        #expect(guest.executable?.path == "/usr/bin/xcrun")
        #expect(guest.runs == [["simctl", "spawn", "duo", "/tmp/builds/abc/HingeControl", "--deadline", "1000.05", "serve"]])
        #expect(guest.written == ["sweep 130 0 800\n", "sweep 0 180 500\n"])
    }

    @Test func `should launch the helper rotation and folding share inside a custom device set`() throws {
        let (motor, guest) = make(deviceSetPath: "/tmp/custom devices")
        try motor.turn(to: .portrait)
        try motor.fold(from: 0, to: 130, over: 0.5)
        #expect(guest.runs == [
            ["simctl", "--set", "/tmp/custom devices", "spawn", "duo", "/tmp/builds/abc/HingeControl", "--deadline", "1000.05", "serve"],
        ])
        #expect(guest.written == ["orientation portrait\n", "sweep 0 130 500\n"])
    }

    @Test func `should keep one shared motor per device set and device identifier`() {
        let udid = UUID().uuidString
        let a = GuestHingeMotor.forDevice(udid, deviceSetPath: "/sets/a")
        #expect(a === GuestHingeMotor.forDevice(udid, deviceSetPath: "/sets/a"))
        #expect(a !== GuestHingeMotor.forDevice(udid, deviceSetPath: "/sets/b"))
        #expect(a !== GuestHingeMotor.forDevice(udid))
        #expect(a !== GuestHingeMotor.forDevice(UUID().uuidString, deviceSetPath: "/sets/a"))
    }

    @Test func `should press a hardware key as Device Hub presses it, for as long as asked`() throws {
        let (motor, guest) = make()
        try motor.press(HIDUsage(page: 12, usage: 233), holding: [], hold: 0.25)
        try motor.press(HIDUsage(page: 0xFF00, usage: 0x66), holding: [], hold: 1.5)
        #expect(guest.written == ["button 12 233 250\n", "button 65280 102 1500\n"])
    }

    @Test func `should press a keyboard key in the guest with its modifiers held`() throws {
        let (motor, guest) = make()
        try motor.press(
            HIDUsage(page: 7, usage: 4),
            holding: [HIDUsage(page: 7, usage: 0xE1), HIDUsage(page: 7, usage: 0xE3)], hold: 0.1)
        try motor.press(HIDUsage(page: 7, usage: 5), holding: [], hold: 0.1)
        #expect(guest.written == ["button 7 4 100 7 225 7 227\n", "button 7 5 100\n"])
    }

    @Test(arguments: [
        (DeviceOrientation.portrait, "portrait"),
        (.portraitUpsideDown, "pud"),
        (.landscapeLeft, "landscape-right"),
        (.landscapeRight, "landscape-left"),
    ])
    func `should rotate using the native physical orientation values`(
        orientation: DeviceOrientation, native: String
    ) throws {
        let (motor, guest) = make()
        try motor.turn(to: orientation)
        #expect(guest.written == ["orientation \(native)\n"])
        // Measured UIDevice values for the native guest commands. The phone
        // backend sends DeviceOrientation.rawValue directly through Purple.
        let physicalValues: [String: UInt32] = [
            "portrait": 1, "pud": 2, "landscape-left": 3, "landscape-right": 4,
        ]
        #expect(physicalValues[native] == orientation.rawValue)
    }

    @Test func `should fail with the guest's status when the guest refuses a command`() {
        let (motor, guest) = make()
        guest.answer = { _ in ["done 1\n"] }
        #expect(throws: HingeError.toolFailed(status: 1)) { try motor.turn(to: .portrait) }
        guest.answer = { _ in ["done 2\n"] }
        #expect(throws: HingeError.toolFailed(status: 2)) { try motor.fold(from: 0, to: 130, over: 0.5) }
    }

    @Test func `should understand answers split across reads and mixed with diagnostics`() throws {
        let (motor, guest) = make()
        guest.greeting = "runtime warning\npi"
        guest.answer = { _ in ["d 4242\nbad line: x\ndo", "ne 0\n"] }
        try motor.turn(to: .landscapeLeft)
    }

    @Test func `should stop the guest helper and time out when a command is not answered`() throws {
        let (motor, guest) = make()
        guest.answer = { _ in [] }
        #expect(throws: HingeError.toolTimedOut) { try motor.turn(to: .portrait) }
        #expect(guest.stopped == [4242])
        #expect(guest.killed == 1)
        guest.answer = { _ in ["done 0\n"] }
        try motor.turn(to: .portrait)
        #expect(guest.runs.count == 2)
    }

    @Test func `should still abandon an unanswering helper when it never announced its pid`() {
        let (motor, guest) = make()
        guest.greeting = nil
        guest.answer = { _ in [] }
        #expect(throws: HingeError.toolTimedOut) { try motor.fold(from: 0, to: 130, over: 0) }
        #expect(guest.stopped.isEmpty)
        #expect(guest.killed == 1)
    }

    @Test func `should fail when the helper ends without answering, and start another for the next command`() throws {
        let (motor, guest) = make()
        guest.answer = { _ in [] }
        guest.exitOnWrite = 164
        #expect(throws: HingeError.toolFailed(status: 164)) { try motor.fold(from: 0, to: 130, over: 0.5) }
        guest.answer = { _ in ["done 0\n"] }
        guest.exitOnWrite = nil
        try motor.fold(from: 130, to: 0, over: 0.5)
        #expect(guest.runs.count == 2)
    }

    /// Under load a spawn can outlast the helper's deadline; it then exits
    /// 3 having done nothing, which is a definite failure, not a timeout.
    @Test func `should report nothing was delivered when the helper started after its deadline`() {
        let (motor, guest) = make()
        guest.answer = { _ in [] }
        guest.exitOnWrite = 3
        #expect(throws: HingeError.toolStartedLate) { try motor.turn(to: .portraitUpsideDown) }
        #expect(String(describing: HingeError.toolStartedLate)
            == "HingeControl started after its deadline and did nothing; the command was not delivered.")
    }

    @Test func `should explain on a timeout that the stopped helper cannot act later`() {
        #expect(String(describing: HingeError.toolTimedOut)
            == "HingeControl did not answer in time; the command may have been delivered, but the stopped helper cannot deliver it later.")
    }

    @Test func `should start the tool again for the next sweep when it went away`() throws {
        let (motor, guest) = make()
        try motor.fold(from: 0, to: 130, over: 0.8)
        guest.onExit?(0)
        try motor.fold(from: 130, to: 0, over: 0.8)
        #expect(guest.runs.count == 2)
    }

    @Test func `should fail when the tool is missing or cannot be spawned`() {
        let (missing, _) = make(tool: nil)
        #expect(throws: HingeError.toolMissing) { try missing.fold(from: 0, to: 130, over: 0.5) }
        let (failing, _) = make(spawnFails: true)
        #expect(throws: HingeError.toolFailed(status: 1)) { try failing.fold(from: 0, to: 130, over: 0.5) }
    }
}
