import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette notify` against the devices a test hands it.
@Suite("Notify command")
struct NotifyCommandTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    private let payload = #"{"aps":{"alert":{"title":"Hi"}}}"#

    private func notifying(failing: Bool = false) -> any Devices {
        let notify = MockNotify()
        if failing {
            given(notify).deliver(.any).willThrow(Refused())
        } else {
            given(notify).deliver(.any).willReturn()
        }
        return routeDevices { $0.register(.notify) { notify } }
    }

    @Test func `should deliver the notification piped in and say what the user should see`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--stdin"]),
            on: notifying(), terminal: Terminal(lines: [payload]))

        #expect(ran.exit == 0)
        #expect(ran.told.first?.hasPrefix("Notified com.x on iPhone 17.") == true)
    }

    @Test func `should answer the delivered notification as JSON when asked`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--stdin", "--json"]),
            on: notifying(), terminal: Terminal(lines: [payload]))

        let answer = try #require(
            JSONSerialization.jsonObject(with: Data(ran.said.joined().utf8)) as? [String: Any])
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["app"] as? String == "com.x")
    }

    @Test func `should deliver the notification read from a file`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notify-\(UUID()).json")
        try Data(payload.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--file", file.path]), on: notifying())

        #expect(ran.exit == 0)
    }

    @Test func `should exit 1 when the file can't be read`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--file", "/nonexistent/n.json"]),
            on: notifying())

        #expect(ran.exit == 1)
        #expect(ran.told == ["cannot read /nonexistent/n.json"])
    }

    @Test func `should exit 1 answering JSON when the payload is not a notification`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--stdin", "--json"]),
            on: notifying(), terminal: Terminal(lines: ["[]"]))

        #expect(ran.exit == 1)
        #expect(ran.said.first?.hasPrefix(#"{"ok":false,"error":"#) == true)
    }

    @Test func `should exit 1 when no device has the udid`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "NOPE", "--bundle-id", "com.x", "--stdin"]),
            on: notifying(), terminal: Terminal(lines: [payload]))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Device NOPE not found"])
    }

    @Test func `should exit 1 when the device can't take notifications`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--stdin"]),
            on: routeDevices(), terminal: Terminal(lines: [payload]))

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do notify"])
    }

    @Test func `should exit 1 when delivery fails`() async throws {
        let ran = try await run(
            try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--stdin"]),
            on: notifying(failing: true), terminal: Terminal(lines: [payload]))

        #expect(ran.exit == 1)
        #expect(ran.told == ["notify failed: refused"])
    }
}
