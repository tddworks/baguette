import Foundation
import Testing

@testable import Baguette

@Suite("SimctlCapture")
struct SimctlCaptureTests {
    @Test func `enumeration preserves the resolved custom device set`() throws {
        let script = try Script("printf '%s\\n' \"$@\"")
        defer { script.remove() }
        let output = try SimctlCapture.enumerate(
            udid: "device-id", deviceSetPath: "/custom set/Devices", xcrun: script.url)
        #expect(output == "simctl\n--set\n/custom set/Devices\nio\ndevice-id\nenumerate\n")
    }

    @Test func `default enumeration does not override the device set`() throws {
        let script = try Script("printf '%s\\n' \"$@\"")
        defer { script.remove() }
        #expect(
            try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url)
                == "simctl\nio\ndevice-id\nenumerate\n")
    }

    @Test func `output larger than the pipe buffer is drained completely`() throws {
        let script = try Script("/usr/bin/head -c 262144 /dev/zero; printf end")
        defer { script.remove() }
        let output = try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url, timeout: 10)
        #expect(output.utf8.count == 262147)
        #expect(output.hasSuffix("end"))
    }

    @Test func `capture finishes while every dispatch worker is blocked`() async {
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

    @Test func `a child that closes output but ignores termination is killed at the deadline`() throws {
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

    @Test func `failed enumeration retains the device status and diagnostics`() throws {
        let script = try Script("echo 'CoreSimulator unavailable' >&2; exit 7")
        defer { script.remove() }
        #expect(
            throws: SimctlCapture.Failure.failed(
                udid: "device-id", status: 7, output: "CoreSimulator unavailable\n")
        ) {
            try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url)
        }
    }

    @Test func `timeout cancels an open output pipe and releases its reader`() async throws {
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

    @Test func `launch failure releases the output reader without waiting for the deadline`() async throws {
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

    @Test func `both output channels drain beyond pipe capacity without mixing`() throws {
        let script = try Script(
            "/usr/bin/head -c 262144 /dev/zero; /usr/bin/head -c 262144 /dev/zero >&2; printf out; printf err >&2")
        defer { script.remove() }
        let output = try SimctlCapture.run(udid: "device-id", arguments: [], xcrun: script.url, timeout: 10)
        #expect(output.stdout.utf8.count == 262147)
        #expect(output.stdout.hasSuffix("out"))
        #expect(output.stderr.utf8.count == 262147)
        #expect(output.stderr.hasSuffix("err"))
    }

    @Test func `display enumeration keeps successful stderr output`() throws {
        let script = try Script("printf display; printf diagnostic >&2")
        defer { script.remove() }
        #expect(try SimctlCapture.enumerate(udid: "device-id", xcrun: script.url) == "displaydiagnostic")
    }

    @Test func `failed commands retain both output channels`() throws {
        let script = try Script("printf output; printf diagnostic >&2; exit 7")
        defer { script.remove() }
        #expect(throws: SimctlCapture.Failure.failed(udid: "device-id", status: 7, output: "outputdiagnostic")) {
            try SimctlCapture.run(udid: "device-id", arguments: [], xcrun: script.url)
        }
    }

    @Test func `timeout retains partial output from both channels`() throws {
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

    @Test func `an inherited stderr writer cannot hold the caller past its deadline`() async throws {
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

    private static func expectClosed(_ handle: FileHandle) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            do {
                _ = try handle.read(upToCount: 0)
            } catch {
                #expect(error is CocoaError)
                return
            }
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
