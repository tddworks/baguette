import Foundation
import Testing

@testable import Baguette

@Suite("AX frontmost resolution")
struct AXFrontmostTests {
    @Test func `only a positive guest process identifier is accepted`() throws {
        #expect(try AXFrontmost.pid(from: Data("{\"pid\":23888}".utf8)) == 23888)
        for json in ["{\"pid\":0}", "{\"pid\":-1}", "{\"pid\":2147483648}", "{}", "error"] {
            #expect(throws: (any Error).self) {
                try AXFrontmost.pid(from: Data(json.utf8))
            }
        }
    }

    @Test func `the terminal response survives preceding guest output without reusing an old pid`() throws {
        #expect(try AXFrontmost.pid(from: Data("banner\n{\"pid\":99}\n{\"pid\":123}\n".utf8)) == 123)
        for terminal in ["{\"pid\":0}", "{\"pid\":2147483648}", "malformed"] {
            #expect(throws: (any Error).self) {
                try AXFrontmost.pid(from: Data("{\"pid\":99}\n\(terminal)\n".utf8))
            }
        }
    }

    @Test func `the current target and device set select the frontmost process`() throws {
        let script = try Script(
            "[ \"$2\" = --set ] && [ \"$3\" = '/custom set' ] && [ \"$4\" = spawn ] && [ \"$6\" = '/guest tool' ] && [ \"$7\" = frontmost ] || exit 9; printf '{\"pid\":%s}' \"$5\""
        )
        defer { script.remove() }
        for udid in ["123", "456"] {
            #expect(
                try GuestFrontmost.pid(
                    udid: udid, deviceSetPath: "/custom set", tool: { "/guest tool" }, xcrun: script.url
                ) == Int32(udid))
        }
    }

    @Test func `each query reads the current frontmost process for the same device`() throws {
        let script = try Script("cat \"$0.pid\"")
        defer { script.remove() }
        for pid in [123, 456] {
            try Data("{\"pid\":\(pid)}".utf8).write(to: script.url.appendingPathExtension("pid"))
            #expect(try GuestFrontmost.pid(udid: "device", tool: { "/guest tool" }, xcrun: script.url) == pid)
        }
    }

    @Test func `each failure names what went wrong`() {
        #expect(
            AXFrontmost.Failure.invalidPID(0).localizedDescription
                == "The guest frontmost query returned an invalid process identifier: 0.")
        #expect(GuestFrontmost.Failure.toolMissing.localizedDescription.contains("HingeControl guest helper is missing"))
        #expect(
            GuestFrontmost.Failure.invalidResponse(udid: "device", cause: "banner").localizedDescription
                == "Frontmost application query for device returned invalid data: banner")
    }

    @Test func `a missing or failed guest query is an explicit failure`() throws {
        #expect(throws: GuestFrontmost.Failure.toolMissing) {
            try GuestFrontmost.pid(udid: "device", tool: { nil })
        }
        let script = try Script("echo 'frontmost unavailable' >&2; exit 7")
        defer { script.remove() }
        #expect(throws: SimctlCapture.Failure.failed(udid: "device", status: 7, output: "frontmost unavailable\n")) {
            try GuestFrontmost.pid(udid: "device", tool: { "/guest tool" }, xcrun: script.url)
        }
    }

    @Test func `guest diagnostics do not corrupt the frontmost process response`() throws {
        let script = try Script("printf 'simctl diagnostic\\n' >&2; printf '{\"pid\":123}'")
        defer { script.remove() }
        #expect(try GuestFrontmost.pid(udid: "device", tool: { "/guest tool" }, xcrun: script.url) == 123)
    }

    @Test func `malformed guest output retains the guest diagnostic`() throws {
        let script = try Script("printf invalid; printf 'guest diagnostic' >&2")
        defer { script.remove() }
        do {
            _ = try GuestFrontmost.pid(udid: "device", tool: { "/guest tool" }, xcrun: script.url)
            Issue.record("Malformed guest output must fail")
        } catch GuestFrontmost.Failure.invalidResponse(let udid, let cause) {
            #expect(udid == "device")
            #expect(cause.contains("invalid"))
            #expect(cause.contains("guest diagnostic"))
        }
    }

    private struct Script {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var url: URL { directory.appendingPathComponent("xcrun") }

        init(_ body: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
