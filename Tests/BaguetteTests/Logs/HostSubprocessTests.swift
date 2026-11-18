import Testing
import Foundation
@testable import Baguette

/// `HostSubprocess` is the one file in the spawn path that talks to the
/// real OS, so everything else is unit-tested against `MockSubprocess`
/// and this is normally left to a manual smoke test.
///
/// It earns real coverage anyway, because two of its behaviours are load
/// bearing and invisible from the mock: the **stdin** path carries a
/// plugin command's arguments, and the **environment** it hands the
/// child is what a plugin reads `BAGUETTE_URL` / `BAGUETTE_TOKEN` from.
/// Both are exercised here with tiny, deterministic system binaries —
/// no simulator, no network, milliseconds each.
@Suite("HostSubprocess")
struct HostSubprocessTests {

    /// How long to wait for a real child to report its exit.
    ///
    /// Deliberately far longer than any of these spawns needs. It is a
    /// backstop against hanging the suite forever, **not** an assertion
    /// about speed — every wait returns the moment the child's exit
    /// callback fires, so a generous bound costs nothing when the
    /// machine is idle.
    ///
    /// It has to be generous because these are the only tests here that
    /// depend on the OS scheduling something. Swift Testing runs suites
    /// in parallel, and this package's media suites do real AVFoundation
    /// decode/encode — on a two-core CI runner they saturate it, and a
    /// SIGTERM round-trip that takes milliseconds locally has been seen
    /// to take over ten seconds there. Tight deadlines here fail on load
    /// rather than on behaviour, and do it invisibly on a dev machine.
    static let childDeadline: Duration = .seconds(90)

    @Test func `should deliver the child's output and report its exit code`() async throws {
        let run = try await Self.spawn(
            executable: "/bin/echo", arguments: ["hello from the child"]
        )
        #expect(run.status == 0)
        #expect(run.output.contains("hello from the child"))
    }

    @Test func `should hand over all of the child's output before reporting its exit`() async throws {
        // devicectl's pasteboard text is read at exit; a chunk still in the
        // pipe then would be a truncated paste. A slow reader — a loaded
        // machine — gives the exit every chance to overtake the output.
        for _ in 0..<3 {
            let subprocess = HostSubprocess()
            let collected = Collected()
            let finished = Finished()
            try subprocess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a"],
                onBytes: { Thread.sleep(forTimeInterval: 0.02); collected.append($0) },
                onExit: { _ in finished.complete(Int32(collected.count)) }
            )
            let countAtExit = try await finished.value(timeout: Self.childDeadline)
            #expect(countAtExit == 300_000)
        }
    }

    @Test func `should report a non-zero exit as its own status`() async throws {
        // Every caller's failure branch keys off this — `SimctlInterface`
        // and `SimctlStatusBar` both turn it into a typed error.
        let run = try await Self.spawn(executable: "/bin/sh", arguments: ["-c", "exit 7"])
        #expect(run.status == 7)
    }

    @Test func `should fold the child's stderr into the same output as stdout`() async throws {
        // Both pipes share one handle, so a tool that diagnoses on
        // stderr still reaches the caller rather than vanishing.
        let run = try await Self.spawn(
            executable: "/bin/sh", arguments: ["-c", "echo to-stderr 1>&2"]
        )
        #expect(run.output.contains("to-stderr"))
    }

    // MARK: - end of output

    /// `FileHandle.readabilityHandler` keeps firing with empty data once
    /// the pipe reaches end-of-file until it is cleared — a busy loop.
    /// A child that exits on its own (every one-shot `simctl`, a
    /// `devicectl` monitor whose timeout lands) must not leave one
    /// behind: `serve` was found pinned at 100% by two of these.
    @Test func `should stop reading a child that exits on its own`() async throws {
        let sub = HostSubprocess()
        let finished = Finished()
        try sub.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["bye"],
            onBytes: { _ in }, onExit: { finished.complete($0) }
        )
        _ = try await finished.value(timeout: Self.childDeadline)
        // The reader is released shortly after EOF; give the source a
        // moment to deliver it.
        for _ in 0..<50 where sub.isReading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!sub.isReading, "the pipe is still being read after the child exited")
    }

    // MARK: - descriptors

    /// `Process` closes the parent's copy of the stdout pipe's write end
    /// as soon as the child is spawned — it is the child's descriptor
    /// now — and the kernel hands that number to the next thing that
    /// asks. A terminate that then closes "our" write end closes that
    /// stranger instead: `xcode-select -p`'s pipe died of
    /// `readDataOfLength: Bad file descriptor` in `serve` once a
    /// long-lived hinge watch put terminates next to other spawns.
    @Test func `should leave a reused file descriptor open when the child is stopped`() async throws {
        let sub = HostSubprocess()
        try sub.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            onBytes: { _ in }, onExit: { _ in }
        )
        // Give Foundation the moment it needs to release the write end,
        // then take whatever descriptor comes next: with the bug, that
        // is the number `terminate()` is about to close.
        try await Task.sleep(for: .milliseconds(200))
        let bystander = Pipe()
        let fd = bystander.fileHandleForReading.fileDescriptor

        sub.terminate()

        #expect(fcntl(fd, F_GETFD) != -1, "terminate closed a descriptor it did not own")
        try? bystander.fileHandleForReading.close()
        try? bystander.fileHandleForWriting.close()
    }

    /// The same, one step later: `terminate()` closed the read end, so
    /// its number is free and the next pipe takes it. When the
    /// `HostSubprocess` is then released, its `deinit` must not close
    /// that end a second time — that is the stranger's descriptor now.
    @Test func `should not close reused file descriptors when a stopped child is released`() async throws {
        var sub: HostSubprocess? = HostSubprocess()
        try sub!.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            onBytes: { _ in }, onExit: { _ in }
        )
        try await Task.sleep(for: .milliseconds(200))
        sub!.terminate()
        let bystander = Pipe()
        let fds = [bystander.fileHandleForReading.fileDescriptor, bystander.fileHandleForWriting.fileDescriptor]

        sub = nil

        for fd in fds {
            #expect(fcntl(fd, F_GETFD) != -1, "deinit closed descriptor \(fd), which it no longer owned")
        }
        try? bystander.fileHandleForReading.close()
        try? bystander.fileHandleForWriting.close()
    }

    // MARK: - stdin

    @Test func `should deliver a stdin payload to the child`() async throws {
        // This is the channel a plugin command reads its context and
        // `args` from — the path where a dropped payload looks like a
        // click that did nothing.
        let payload = #"{"command":"a11y:display","args":{"appearance":"dark"}}"#
        let run = try await Self.spawn(
            executable: "/bin/cat", arguments: [], stdin: Data(payload.utf8)
        )
        #expect(run.status == 0)
        #expect(run.output == payload)
    }

    @Test func `should not deadlock when the stdin payload exceeds the pipe buffer`() async throws {
        // Written off the calling thread on purpose: anything past the
        // ~64 KB pipe buffer would otherwise block the spawn until the
        // child drained it, and the child can't run until the spawn
        // returns.
        let payload = String(repeating: "x", count: 256 * 1024)
        let run = try await Self.spawn(
            executable: "/bin/cat", arguments: [], stdin: Data(payload.utf8)
        )
        #expect(run.status == 0)
        #expect(run.output.count == payload.count)
    }

    @Test func `should end stdin after the payload so the child can finish`() async throws {
        // `wc -c` only answers once the stream ends. If the handle were
        // left open the child would hang and the test would time out.
        let run = try await Self.spawn(
            executable: "/usr/bin/wc", arguments: ["-c"], stdin: Data("12345".utf8)
        )
        #expect(run.status == 0)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "5")
    }

    // MARK: - working directory and environment

    @Test func `should run the child in the working directory it was given`() async throws {
        // A plugin's command is spawned with its own directory as cwd,
        // which is what makes a relative `["python3", "bin/x.py"]` work.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let run = try await Self.spawn(
            executable: "/bin/pwd", arguments: [],
            stdin: Data(), workingDirectory: tmp, environment: [:]
        )
        // /var vs /private/var — compare the resolved paths.
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(
            tmp.lastPathComponent
        ))
    }

    @Test func `should replace the parent's environment rather than merge when one is supplied`() async throws {
        // The documented contract, and the reason a plugin sees exactly
        // the three BAGUETTE_ vars it was handed. A merge would leak the
        // server's whole environment into third-party code.
        setenv("BAGUETTE_TEST_LEAK", "should-not-appear", 1)
        defer { unsetenv("BAGUETTE_TEST_LEAK") }

        let run = try await Self.spawn(
            executable: "/usr/bin/env", arguments: [],
            stdin: Data(),
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["BAGUETTE_TOKEN": "abc123"]
        )
        #expect(run.output.contains("BAGUETTE_TOKEN=abc123"))
        #expect(!run.output.contains("BAGUETTE_TEST_LEAK"))
    }

    // MARK: - termination

    @Test func `should stop a child that would otherwise outlive baguette`() async throws {
        // The timeout path: `PluginDispatch` terminates a command that
        // overran, and `SimDeviceLogStream` terminates on teardown.
        let subprocess = HostSubprocess()
        let finished = Finished()

        try subprocess.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            // Must outlast the deadline below by a wide margin: a child
            // that exits *on its own* would report status 0 and fail
            // this test for a reason that has nothing to do with
            // `terminate()`.
            arguments: ["300"],
            onBytes: { _ in },
            onExit: { status in finished.complete(status) }
        )
        subprocess.terminate()

        let status = try await finished.value(timeout: Self.childDeadline)
        // Signalled, not a clean exit.
        #expect(status != 0)
    }

    @Test func `should do no harm when stopping a child that already finished`() async throws {
        let run = try await Self.spawn(executable: "/usr/bin/true", arguments: [])
        #expect(run.status == 0)
        // The subprocess has already exited; this must not trap.
        run.subprocess.terminate()
    }

    @Test func `should fail to start rather than report a fake exit when the executable is missing`() async throws {
        let subprocess = HostSubprocess()
        #expect(throws: (any Error).self) {
            try subprocess.run(
                executable: URL(fileURLWithPath: "/definitely/not/a/binary"),
                arguments: [],
                onBytes: { _ in },
                onExit: { _ in }
            )
        }
    }

    // MARK: - helpers

    struct Run {
        let status: Int32
        let output: String
        let subprocess: HostSubprocess
    }

    /// One-shot await over the callback API. Everything the child writes
    /// is accumulated; the continuation resumes on exit.
    static func spawn(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> Run {
        let subprocess = HostSubprocess()
        let collected = Collected()
        let finished = Finished()
        let url = URL(fileURLWithPath: executable)

        if let workingDirectory, let environment {
            try subprocess.run(
                executable: url, arguments: arguments,
                workingDirectory: workingDirectory, environment: environment,
                stdin: stdin ?? Data(),
                onBytes: { collected.append($0) },
                onExit: { finished.complete($0) }
            )
        } else if let stdin {
            try subprocess.run(
                executable: url, arguments: arguments, stdin: stdin,
                onBytes: { collected.append($0) },
                onExit: { finished.complete($0) }
            )
        } else {
            try subprocess.run(
                executable: url, arguments: arguments,
                onBytes: { collected.append($0) },
                onExit: { finished.complete($0) }
            )
        }

        let status = try await finished.value(timeout: Self.childDeadline)
        // The readability handler can fire after termination; give the
        // last chunk a moment to land rather than racing it.
        try? await Task.sleep(for: .milliseconds(60))
        return Run(status: status, output: collected.string, subprocess: subprocess)
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return data.count }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A one-shot exit signal that can be awaited, with a timeout so a
    /// hung child fails the test instead of hanging the suite.
    final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?

        func complete(_ code: Int32) {
            lock.lock(); defer { lock.unlock() }
            if status == nil { status = code }
        }

        private var current: Int32? {
            lock.lock(); defer { lock.unlock() }
            return status
        }

        func value(timeout: Duration) async throws -> Int32 {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let status = current { return status }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ChildTimedOut()
        }
    }

    struct ChildTimedOut: Error {}

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-subprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
