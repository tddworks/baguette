import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette logs`: the filter its flags ask for, and a session that
/// follows the device's log until it ends or the user stops it.
@Suite("Logs command")
struct LogsCommandTests {

    // MARK: - filter

    @Test func `should follow info-level logs in the default style when no flags are given`() throws {
        let cmd = try LogsCommand.parse(["--udid", "U"])

        #expect(try cmd.filter() == LogFilter(level: .info, style: .default, predicate: nil, bundleId: nil))
    }

    @Test func `should follow logs filtered by the predicate and bundle id given`() throws {
        let cmd = try LogsCommand.parse(
            ["--udid", "U", "--level", "debug", "--style", "compact",
             "--predicate", "subsystem == \"x\"", "--bundle-id", "com.example"])

        #expect(try cmd.filter() == LogFilter(
            level: .debug, style: .compact, predicate: "subsystem == \"x\"", bundleId: "com.example"))
    }

    @Test func `should refuse a level it doesn't know, naming the ones it does`() throws {
        let cmd = try LogsCommand.parse(["--udid", "U", "--level", "loud"])

        #expect(throws: ArgumentRefusal("logs: invalid --level 'loud' (use \(LogsCommand.levels))")) {
            try cmd.filter()
        }
    }

    @Test func `should refuse a style it doesn't know, naming the ones it does`() throws {
        let cmd = try LogsCommand.parse(["--udid", "U", "--style", "fancy"])

        #expect(throws: ArgumentRefusal("logs: invalid --style 'fancy' (use \(LogsCommand.styles))")) {
            try cmd.filter()
        }
    }

    // MARK: - session

    @Test func `should write every line the device logs until its stream ends`() async throws {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willProduce { _, onLine, onTerminate in
            onLine("first")
            onLine("second")
            onTerminate(nil)
        }
        let output = Lines()

        try await LogsSession(stream: stream, write: output.add, warn: output.add)
            .follow(LogFilter(level: .info, style: .default, predicate: nil, bundleId: nil))

        #expect(output.all == ["first", "second"])
    }

    @Test func `should say why when the device's log stream ends in an error`() async throws {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willProduce { _, _, onTerminate in
            onTerminate(LogStreamError.nonZeroExit(code: 3))
        }
        let warnings = Lines()

        try await LogsSession(stream: stream, write: { _ in }, warn: warnings.add)
            .follow(LogFilter(level: .info, style: .default, predicate: nil, bundleId: nil))

        #expect(warnings.all == ["logs: stream ended: nonZeroExit(code: 3)"])
    }

    @Test func `should end the session when the user stops it`() async throws {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willReturn()
        given(stream).stop().willReturn()
        let session = LogsSession(stream: stream, write: { _ in }, warn: { _ in })

        session.stop()
        try await session.follow(LogFilter(level: .info, style: .default, predicate: nil, bundleId: nil))

        verify(stream).stop().called(1)
    }

    @Test func `should fail the session when the stream can't start`() async {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any)
            .willThrow(LogStreamError.spawnFailed(reason: "no log"))
        let session = LogsSession(stream: stream, write: { _ in }, warn: { _ in })

        await #expect(throws: LogStreamError.spawnFailed(reason: "no log")) {
            try await session.follow(LogFilter(level: .info, style: .default, predicate: nil, bundleId: nil))
        }
    }
}

/// Lines a command wrote, collected in order.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var all: [String] { lock.withLock { lines } }

    @Sendable func add(_ line: String) { lock.withLock { lines.append(line) } }
}

/// What a command said on stdout and stderr, each in order.
final class OutputLines: Sendable {
    private let printed = Lines()
    private let logged = Lines()

    var said: [String] { printed.all }
    var warned: [String] { logged.all }
    var sink: CommandOutput { CommandOutput(say: printed.add, warn: logged.add) }
}
