import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

@Suite("SimctlCapture")
struct SimctlCaptureTests {
    @Test func `should enumerate displays inside the resolved custom device set`() throws {
        let script = try Script("printf '%s\\n' \"$@\"")
        defer { script.remove() }
        let output = try SimctlCapture.enumerate(
            udid: "device-id", deviceSetPath: "/custom set/Devices", xcrun: script.url)
        #expect(output == "simctl\n--set\n/custom set/Devices\nio\ndevice-id\nenumerate\n")
    }

    @Test func `should leave the device set alone when enumerating the default set`() throws {
        let script = try Script("printf '%s\\n' \"$@\"")
        defer { script.remove() }
        #expect(
            try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url)
                == "simctl\nio\ndevice-id\nenumerate\n")
    }

    @Test func `should capture all output when it is larger than the pipe buffer`() throws {
        let script = try Script("/usr/bin/head -c 262144 /dev/zero; printf end")
        defer { script.remove() }
        let output = try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url, timeout: 10)
        #expect(output.utf8.count == 262147)
        #expect(output.hasSuffix("end"))
    }

    @Test func `should finish a capture when every dispatch worker is blocked`() async {
        // Isolate process-wide worker starvation from other subprocess deadline tests.
        await #expect(processExitsWith: .success) {
            try Self.expectCaptureWithBlockedWorkers()
        }
    }

    private static func expectCaptureWithBlockedWorkers() throws {
        let script = try Script("printf ready")
        defer { script.remove() }
        // A loaded host (a busy `serve`, a full test run) can park every global-queue
        // worker; the capture must not depend on one becoming free.
        let release = DispatchSemaphore(value: 0)
        let blockers = 128
        let started = DispatchGroup()
        for _ in 0..<blockers {
            started.enter()
            DispatchQueue.global().async {
                started.leave()
                release.wait()
            }
        }
        defer { for _ in 0..<blockers { release.signal() } }
        _ = started.wait(timeout: .now() + 0.5)
        #expect(
            try SimctlCapture.run(
                udid: "device-id", arguments: [script.url.path], xcrun: URL(fileURLWithPath: "/bin/sh"), timeout: 2
            ).combined == "ready")
    }

    @Test func `should kill a child at the deadline when it closes its output but ignores termination`() throws {
        let script = try Script("trap '' TERM; exec 1>&- 2>&-; exec /bin/sleep 30")
        defer { script.remove() }
        let process = Process()
        let start = ContinuousClock.now
        #expect(throws: SimctlCapture.Failure.timedOut(udid: "device-id", seconds: 1, processExited: false, output: ""))
        {
            try SimctlCapture.run(
                udid: "device-id", arguments: [script.url.path], xcrun: URL(fileURLWithPath: "/bin/sh"),
                timeout: 1, process: process)
        }
        #expect(start.duration(to: .now) < .seconds(5))
        let pid = process.processIdentifier
        #expect(pid > 0)
        try #require(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func `should report the device, exit status and diagnostics when enumeration fails`() throws {
        let script = try Script("echo 'CoreSimulator unavailable' >&2; exit 7")
        defer { script.remove() }
        #expect(
            throws: SimctlCapture.Failure.failed(
                udid: "device-id", status: 7, output: "CoreSimulator unavailable\n")
        ) {
            try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url)
        }
    }

    @Test func `should close the output pipes and release their readers when a capture times out`() async throws {
        let script = try Script("printf started; exec /bin/sleep 30")
        defer { script.remove() }
        let process = Process()
        let start = ContinuousClock.now
        #expect(
            throws: SimctlCapture.Failure.timedOut(
                udid: "device-id", seconds: 1, processExited: false, output: "started")
        ) {
            try SimctlCapture.run(
                udid: "device-id", arguments: [script.url.path], xcrun: URL(fileURLWithPath: "/bin/sh"),
                timeout: 1, process: process)
        }
        #expect(start.duration(to: .now) < .seconds(5))
        try #require(!process.isRunning)
        #expect(process.terminationStatus == SIGKILL)
        let pipe = try #require(process.standardOutput as? Pipe)
        try await Self.expectClosed(pipe.fileHandleForReading)
        let errorPipe = try #require(process.standardError as? Pipe)
        try await Self.expectClosed(errorPipe.fileHandleForReading)
    }

    @Test func `should release the output readers without waiting for the deadline when launch fails`() async throws {
        let script = try Script("exit 0")
        defer { script.remove() }
        let process = Process()
        let start = ContinuousClock.now
        #expect(throws: CocoaError.self) {
            try SimctlCapture.enumerate(
                udid: "device-id", xcrun: script.directory.appendingPathComponent("missing"),
                timeout: 30, process: process)
        }
        #expect(start.duration(to: .now) < .seconds(5))
        let pipe = try #require(process.standardOutput as? Pipe)
        try await Self.expectClosed(pipe.fileHandleForReading)
        let errorPipe = try #require(process.standardError as? Pipe)
        try await Self.expectClosed(errorPipe.fileHandleForReading)
    }

    @Test func `should capture stdout and stderr separately when both exceed the pipe capacity`() throws {
        let script = try Script(
            "/usr/bin/head -c 262144 /dev/zero; /usr/bin/head -c 262144 /dev/zero >&2; printf out; printf err >&2")
        defer { script.remove() }
        let output = try SimctlCapture.run(udid: "device-id", arguments: [], xcrun: script.url, timeout: 10)
        #expect(output.stdout.utf8.count == 262147)
        #expect(output.stdout.hasSuffix("out"))
        #expect(output.stderr.utf8.count == 262147)
        #expect(output.stderr.hasSuffix("err"))
    }

    @Test func `should keep stderr output when display enumeration succeeds`() throws {
        let script = try Script("printf display; printf diagnostic >&2")
        defer { script.remove() }
        #expect(try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url) == "displaydiagnostic")
    }

    @Test func `should keep both output channels when a command fails`() throws {
        let script = try Script("printf output; printf diagnostic >&2; exit 7")
        defer { script.remove() }
        #expect(throws: SimctlCapture.Failure.failed(udid: "device-id", status: 7, output: "outputdiagnostic")) {
            try SimctlCapture.run(udid: "device-id", arguments: [], xcrun: script.url)
        }
    }

    @Test func `should keep partial output from both channels when a command times out`() throws {
        let script = try Script("printf output; printf diagnostic >&2; exec 1>&- 2>&-; exec /bin/sleep 30")
        defer { script.remove() }
        #expect(
            throws: SimctlCapture.Failure.timedOut(
                udid: "device-id", seconds: 1, processExited: false, output: "outputdiagnostic"
            )
        ) {
            try SimctlCapture.run(
                udid: "device-id", arguments: [script.url.path], xcrun: URL(fileURLWithPath: "/bin/sh"), timeout: 1)
        }
    }

    @Test func `should give up at the deadline when an inherited stderr writer outlives the command`() async throws {
        let script = try Script("/bin/sleep 30 >/dev/null & printf '%s' $! >\"$0.child\"; printf diagnostic >&2")
        let childFile = script.url.appendingPathExtension("child")
        defer {
            if let text = try? String(contentsOf: childFile, encoding: .utf8), let pid = Int32(text) {
                Darwin.kill(pid, SIGKILL)
            }
            script.remove()
        }
        let process = Process()
        let start = ContinuousClock.now
        do {
            _ = try SimctlCapture.run(
                udid: "device-id", arguments: [script.url.path], xcrun: URL(fileURLWithPath: "/bin/sh"),
                timeout: 1, process: process)
            Issue.record("The inherited writer must time out")
        } catch SimctlCapture.Failure.timedOut(let udid, let seconds, _, let output) {
            #expect(udid == "device-id")
            #expect(seconds == 1)
            #expect(output == "diagnostic")
        }
        #expect(start.duration(to: .now) < .seconds(5))
        try #require(!process.isRunning)
        #expect(process.terminationStatus == 0)
        let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
        #expect(Darwin.kill(child, 0) == 0)
        for value in [process.standardOutput, process.standardError] {
            let pipe = try #require(value as? Pipe)
            try await Self.expectClosed(pipe.fileHandleForReading)
        }
    }

    /// A reader that hit EOF closes itself from inside its own readability
    /// handler, and Foundation holds that close until the handler returns.
    /// On a loaded host the handler's thread can be held for seconds (CI runs
    /// that failed here had tests taking 25–33 s), so what is asserted is
    /// that the descriptor is released, not how quickly: the wait is generous,
    /// and the last look comes after the deadline rather than before it.
    private static func expectClosed(_ handle: FileHandle) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do {
                _ = try handle.read(upToCount: 0)
            } catch {
                #expect(error is CocoaError)
                return
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The output reader remained open after cancellation")
    }

    private struct Script {
        let directory: URL
        var url: URL { directory.appendingPathComponent("xcrun") }

        init(_ body: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
