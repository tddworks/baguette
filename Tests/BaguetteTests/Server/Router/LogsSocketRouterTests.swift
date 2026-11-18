import Foundation
import HTTPTypes
import HummingbirdTesting
import HummingbirdWSTesting
import Mockable
import Testing
import WSClient
@testable import Baguette
@testable import BaguetteDevice

/// The unified-log socket, end to end through a loopback listener: the
/// lines a device's log stream emits reach the page in batches, and every
/// way the stream can't start is said on the socket before it closes.
@Suite("Serve router: logs socket")
struct LogsSocketRouterTests {

    /// Every text message the socket sends, until it says it stopped.
    private static func messages(
        _ path: String, devices: any Devices
    ) async throws -> [String] {
        // The test client's Origin is a bare `http://localhost`, no port,
        // so the socket is opened as a page on an allowed host would.
        try await socketConversation(
            path, server: InProcessServer(devices: devices, allowedHosts: ["localhost"]),
            until: { $0.contains("log_stopped") })
    }

    private static func logs(_ start: @escaping @Sendable (
        @escaping @Sendable (String) -> Void, @escaping @Sendable ((any Error)?) -> Void
    ) throws -> Void) -> any Devices {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willProduce { _, onLine, onTerminate in
            try start(onLine, onTerminate)
        }
        given(stream).stop().willReturn()
        return routeDevices { $0.register(.logs) { stream } }
    }

    @Test func `should stream a device's log lines to the page until the stream ends`() async throws {
        let devices = Self.logs { onLine, onTerminate in
            onLine("first line")
            onLine("second line")
            onTerminate(nil)
        }

        let messages = try await Self.messages("/devices/U/logs?level=debug&style=compact", devices: devices)

        #expect(messages.first == #"{"type":"log_started"}"#)
        #expect(messages.contains(#"{"type":"log","lines":["first line","second line"]}"#))
        #expect(messages.last == #"{"type":"log_stopped","reason":"client closed"}"#)
    }

    @Test func `should say why the log socket stopped when the stream can't start`() async throws {
        let devices = Self.logs { _, _ in throw RoleFailed() }

        let messages = try await Self.messages("/simulators/U/logs", devices: devices)

        #expect(messages == [#"{"type":"log_stopped","reason":"role failed"}"#])
    }

    @Test func `should refuse a log level or style it doesn't know`() async throws {
        let devices = Self.logs { _, _ in }

        let level = try await Self.messages("/devices/U/logs?level=loud", devices: devices)
        let style = try await Self.messages("/devices/U/logs?style=fancy", devices: devices)

        #expect(level == [#"{"type":"log_stopped","reason":"invalid level: loud"}"#])
        #expect(style == [#"{"type":"log_stopped","reason":"invalid style: fancy"}"#])
    }

    @Test func `should stop the log socket of a device with no logs or no device`() async throws {
        let none = try await Self.messages("/devices/U/logs", devices: routeDevices())
        let ghost = try await Self.messages("/devices/ghost/logs", devices: routeDevices())

        #expect(none.first?.contains("log_stopped") == true)
        #expect(ghost == [#"{"type":"log_stopped","reason":"unknown udid"}"#])
    }
}

/// Messages collected off a socket's handler.
final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}
