import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// State-machine tests for `SimDeviceLogStream` driven entirely
/// through a `MockSubprocess`. Coverage scope: every byte-flow,
/// state-transition, and error-mapping branch the orchestrator
/// owns. The actual `Foundation.Process` spawn lives behind the
/// `Subprocess` collaborator and is integration-only — these
/// tests don't touch it.
@Suite("SimDeviceLogStream — orchestration via Subprocess")
struct SimDeviceLogStreamOrchestrationTests {

    /// Captures the closures `subprocess.run(...)` was called
    /// with so the test can fire them on demand. Class so the
    /// `@Sendable` callbacks can box mutable state safely.
    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var onBytes:   (@Sendable (Data) -> Void)?
        var onExit:    (@Sendable (Int32) -> Void)?
    }

    /// Bag for mutable state captured by `@Sendable` callbacks
    /// (the orchestrator hands those callbacks off to the mock,
    /// which then re-invokes them — strict concurrency requires
    /// the captured storage to be class-typed).
    final class Recorder<T>: @unchecked Sendable {
        var values: [T] = []
        var fireCount: Int { values.count }
        func record(_ v: T) { values.append(v) }
    }

    private func makeStream(deviceSetPath: String? = nil) -> (SimDeviceLogStream, MockSubprocess, Captures) {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(FakeSimDevice(state: 3))
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any,
            onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.executable = exe
            captures.arguments  = args
            captures.onBytes    = onBytes
            captures.onExit     = onExit
        }
        given(sub).terminate().willReturn()
        let stream = SimDeviceLogStream(udid: "u1", host: host, deviceSetPath: deviceSetPath, subprocess: sub)
        return (stream, sub, captures)
    }

    // MARK: - byte-to-line dispatch

    @Test func `should deliver one log line when a single line arrives in one chunk`() throws {
        let (stream, _, captures) = makeStream()
        let lines = Recorder<String>()
        try stream.start(filter: LogFilter(),
                         onLine: { lines.record($0) },
                         onTerminate: { _ in })
        captures.onBytes?(Data("hello\n".utf8))
        #expect(lines.values == ["hello"])
    }

    @Test func `should hold a partial log line until its newline arrives in a later chunk`() throws {
        let (stream, _, captures) = makeStream()
        let lines = Recorder<String>()
        try stream.start(filter: LogFilter(),
                         onLine: { lines.record($0) },
                         onTerminate: { _ in })
        captures.onBytes?(Data("partial".utf8))
        #expect(lines.values.isEmpty)
        captures.onBytes?(Data(" line\n".utf8))
        #expect(lines.values == ["partial line"])
    }

    @Test func `should deliver each log line when several arrive in one chunk`() throws {
        let (stream, _, captures) = makeStream()
        let lines = Recorder<String>()
        try stream.start(filter: LogFilter(),
                         onLine: { lines.record($0) },
                         onTerminate: { _ in })
        captures.onBytes?(Data("a\nb\nc\n".utf8))
        #expect(lines.values == ["a", "b", "c"])
    }

    // MARK: - termination handling

    @Test func `should end the log stream cleanly when log stream exits with code zero`() throws {
        let (stream, _, captures) = makeStream()
        let term = Recorder<Error?>()
        try stream.start(filter: LogFilter(),
                         onLine: { _ in },
                         onTerminate: { term.record($0) })
        captures.onExit?(0)
        #expect(term.fireCount == 1)
        #expect(term.values.first ?? Optional<Error>.none == nil)
    }

    @Test func `should end the log stream with the exit code when log stream exits non-zero`() throws {
        let (stream, _, captures) = makeStream()
        let term = Recorder<Error?>()
        try stream.start(filter: LogFilter(),
                         onLine: { _ in },
                         onTerminate: { term.record($0) })
        captures.onExit?(137)
        #expect((term.values.first.flatMap { $0 } as? LogStreamError)
            == .nonZeroExit(code: 137))
    }

    // MARK: - lifecycle

    @Test func `should refuse to start a log stream that is already running`() throws {
        let (stream, _, _) = makeStream()
        try stream.start(filter: LogFilter(),
                         onLine: { _ in }, onTerminate: { _ in })
        #expect(throws: LogStreamError.alreadyStarted) {
            try stream.start(filter: LogFilter(),
                             onLine: { _ in }, onTerminate: { _ in })
        }
    }

    @Test func `should stop log stream and end cleanly when stopped`() throws {
        let (stream, sub, _) = makeStream()
        let term = Recorder<Error?>()
        try stream.start(filter: LogFilter(),
                         onLine: { _ in },
                         onTerminate: { term.record($0) })
        stream.stop()
        verify(sub).terminate().called(1)
        #expect(term.fireCount == 1)
        #expect(term.values.first ?? Optional<Error>.none == nil)
    }

    @Test func `should stop log stream only once when stopped twice`() throws {
        let (stream, sub, _) = makeStream()
        try stream.start(filter: LogFilter(),
                         onLine: { _ in }, onTerminate: { _ in })
        stream.stop()
        stream.stop()
        // Subprocess.terminate must only fire once for the first
        // stop; the second is dropped on the orchestrator's
        // `stopped` flag.
        verify(sub).terminate().called(1)
    }

    @Test func `should drop log output that arrives after the stream stopped`() throws {
        let (stream, _, captures) = makeStream()
        let lines = Recorder<String>()
        try stream.start(filter: LogFilter(),
                         onLine: { lines.record($0) },
                         onTerminate: { _ in })
        stream.stop()
        captures.onBytes?(Data("late\n".utf8))
        #expect(lines.values.isEmpty)
    }

    @Test func `should end the log stream only once when the process exits after a stop`() throws {
        let (stream, _, captures) = makeStream()
        let term = Recorder<Error?>()
        try stream.start(filter: LogFilter(),
                         onLine: { _ in },
                         onTerminate: { term.record($0) })
        stream.stop()                // fires onTerminate once
        captures.onExit?(0)          // simulate child wind-down — must NOT fire again
        #expect(term.fireCount == 1)
    }

    // MARK: - argv plumbing

    @Test func `should run xcrun simctl spawn on the device with log stream and the chosen filter`() throws {
        let (stream, _, captures) = makeStream()
        try stream.start(filter: LogFilter(level: .debug, style: .json),
                         onLine: { _ in }, onTerminate: { _ in })
        #expect(captures.executable?.path == "/usr/bin/xcrun")
        // argv shape: ["simctl", "spawn", <udid>, "log", "stream", "--level", "debug", "--style", "json"]
        let argv = captures.arguments ?? []
        #expect(argv.first == "simctl")
        #expect(argv[safe: 1] == "spawn")
        #expect(argv[safe: 2] == "u1")
        #expect(argv[safe: 3] == "log")
        #expect(argv[safe: 4] == "stream")
        #expect(argv.contains("--level"))
        #expect(argv.contains("debug"))
    }

    @Test func `should stream logs from inside the device's custom device set when it lives in one`() throws {
        let (stream, _, captures) = makeStream(deviceSetPath: "/custom set")
        try stream.start(filter: LogFilter(), onLine: { _ in }, onTerminate: { _ in })
        #expect(Array(captures.arguments?.prefix(7) ?? [])
            == ["simctl", "--set", "/custom set", "spawn", "u1", "log", "stream"])
    }

    // MARK: - device-resolution gating still applies

    @Test func `should refuse as not booted before running anything when no device matches the udid`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let sub = MockSubprocess()
        let stream = SimDeviceLogStream(udid: "ghost", host: host, subprocess: sub)

        #expect(throws: LogStreamError.simulatorNotBooted(udid: "ghost")) {
            try stream.start(filter: LogFilter(),
                             onLine: { _ in }, onTerminate: { _ in })
        }
        verify(sub).run(executable: .any, arguments: .any,
                        onBytes: .any, onExit: .any).called(0)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
