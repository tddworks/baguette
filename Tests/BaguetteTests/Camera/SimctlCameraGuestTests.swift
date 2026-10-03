import Foundation
import Testing

@testable import Baguette

@Suite("SimctlCameraGuest")
struct SimctlCameraGuestTests {
    @Test func `camera cleanup queries the actual nested device set selected by CoreSimulator`() throws {
        final class DeviceSet: NSObject {
            @objc let availableDevices: [NSObject]
            init(_ devices: [NSObject]) { availableDevices = devices }
        }
        final class Context: NSObject, @unchecked Sendable {
            @objc func deviceSetWithPath(_ path: NSString, error: AutoreleasingUnsafeMutablePointer<NSError?>?)
                -> NSObject?
            {
                DeviceSet(path.lastPathComponent == "Devices" ? [NSObject()] : [])
            }
        }
        let script = try Script()
        defer { script.remove() }
        let nested = script.directory.appendingPathComponent("Devices")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(
            """
            #!/bin/sh
            [ "$2" = --set ] && [ "$3" = "$(dirname "$0")/Devices" ] || exit 9
            printf '{"devices":{}}'
            """.utf8
        ).write(to: script.url)
        let context = Context()
        let simulators = CoreSimulators(deviceSetPath: script.directory.path, serviceContext: { context })
        #expect(try simulators.hasTerminated(udid: "U", xcrun: script.url))
        let unavailable = CoreSimulators(deviceSetPath: script.directory.path, serviceContext: { nil })
        #expect(throws: (any Error).self) { try unavailable.hasTerminated(udid: "U", xcrun: script.url) }
    }

    @Test func `only shutdown or absence in a successful device-set listing confirms termination`() throws {
        let script = try Script()
        defer { script.remove() }
        for state in ["Booted", "Booting", "ShuttingDown", "Creating", "unknown", "Shutdown"] {
            try script.output(#"{"devices":{"runtime":[{"udid":"U","state":"\#(state)"}]}}"#)
            #expect(
                try SimctlCameraGuest.hasTerminated(udid: "u", deviceSetPath: "/custom set", xcrun: script.url)
                    == (state == "Shutdown"))
        }
        try script.output(#"{"devices":{"runtime":[{"udid":"V","state":"Booted"}]}}"#)
        #expect(try SimctlCameraGuest.hasTerminated(udid: "U", deviceSetPath: "/custom set", xcrun: script.url))
    }

    @Test func `failed or malformed listings cannot prove deletion`() throws {
        let script = try Script()
        defer { script.remove() }
        for output in ["not JSON", "{}", #"{"devices":{"runtime":[{"udid":"U"}]}}"#] {
            try script.output(output)
            #expect(throws: (any Error).self) {
                try SimctlCameraGuest.hasTerminated(udid: "U", deviceSetPath: "/custom set", xcrun: script.url)
            }
        }
        try script.output(#"{"devices":{}}"#)
        try Data("exit 7\n".utf8).write(to: script.url.appendingPathExtension("exit"))
        #expect(throws: (any Error).self) {
            try SimctlCameraGuest.hasTerminated(udid: "U", deviceSetPath: "/custom set", xcrun: script.url)
        }
    }

    private struct Script {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var url: URL { directory.appendingPathComponent("xcrun") }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(
                """
                #!/bin/sh
                [ "$1" = simctl ] && [ "$2" = --set ] && [ "$3" = '/custom set' ] && [ "$4" = list ] && [ "$5" = devices ] && [ "$6" = --json ] || exit 9
                cat "$0.json"
                if [ -f "$0.exit" ]; then . "$0.exit"; fi
                """.utf8
            ).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        func output(_ text: String) throws { try Data(text.utf8).write(to: url.appendingPathExtension("json")) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
