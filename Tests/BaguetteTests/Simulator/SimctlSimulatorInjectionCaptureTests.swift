import Foundation
import Mockable
import Testing

@testable import Baguette

@Suite("SimctlSimulatorInjectionCapture")
struct SimctlSimulatorInjectionCaptureTests {
    private let camera = "/Library/Application Support/Baguette/builds/e4b2efe8eb36/VirtualCamera.dylib"
    private let motion = "/builds/current/VirtualMotion.dylib"

    @Test func `camera and motion preserve each other despite guest constructor diagnostics on stderr`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        let diagnostics = """
            2026-09-28 23:23:26.075 launchctl[496:25932526] [SimCamInject] AVCaptureSession startRunning: hooked
            2026-09-28 23:23:26.077 launchctl[496:25932526] [SimCamInject] UIImagePickerController hooks installed
            2026-09-28 23:23:26.077 launchctl[496:25932526] [SimCamInject] AVCaptureVideoPreviewLayer setSession: hooked
            2026-09-28 23:23:26.078 launchctl[496:25932526] [SimCamVC] virtual-camera capture graph installed
            """ + "\n"
        try fixture.output(camera + "\n", stderr: diagnostics)
        try await fixture.injection.arm(dylibPath: motion, on: fixture.simulator)
        #expect(try fixture.written() == camera + ":" + motion)
        try fixture.output(camera + ":" + motion + "\n", stderr: diagnostics)
        try await fixture.injection.disarm(dylibPath: camera, on: fixture.simulator)
        #expect(try fixture.written() == motion)
    }

    @Test func `unknown environment reads fail without changing another injection`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        for (stdout, stderr, status) in [("", "simulator unavailable", 1), (camera, "", 1), ("", "", 2)] {
            try fixture.output(stdout, stderr: stderr, status: status)
            let failure = SimctlCapture.Failure.failed(udid: "U", status: Int32(status), output: stdout + stderr)
            await #expect(throws: failure) {
                try await fixture.injection.arm(dylibPath: motion, on: fixture.simulator)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.writeURL.path))
            await #expect(throws: failure) {
                try await fixture.injection.disarm(dylibPath: camera, on: fixture.simulator)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.writeURL.path))
        }
    }

    @Test func `armed query surfaces an unknown environment rather than reporting disarmed`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", stderr: "simulator unavailable", status: 1)
        await #expect(throws: SimctlCapture.Failure.failed(udid: "U", status: 1, output: "simulator unavailable")) {
            try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator)
        }
    }

}

struct SimulatorInjectionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var executable: URL { directory.appendingPathComponent("xcrun") }
    var writeURL: URL { directory.appendingPathComponent("written") }
    var injection: SimctlSimulatorInjection { SimctlSimulatorInjection(xcrun: executable) }
    let simulator = MockSimulator()

    init() throws {
        given(simulator).udid.willReturn("U")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            """
            #!/bin/sh
            cd "$(dirname "$0")" || exit 9
            [ "$1" = simctl ] && [ "$2" = spawn ] && [ "$3" = U ] && [ "$4" = launchctl ] && [ "$6" = DYLD_INSERT_LIBRARIES ] || exit 9
            printf '%s\n' "$@" > "$5.args"
            case "$5" in
                getenv) cat stderr >&2; cat stdout; exit "$(cat status)" ;;
                setenv) printf '%s' "$7" > written; exit "$(cat write-status)" ;;
                unsetenv) : > written; exit "$(cat write-status)" ;;
                *) exit 9 ;;
            esac
            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("0".utf8).write(to: directory.appendingPathComponent("write-status"))
    }

    func output(_ stdout: String, stderr: String = "", status: Int = 0) throws {
        for (name, value) in [("stdout", stdout), ("stderr", stderr), ("status", String(status))] {
            try Data(value.utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    func written() throws -> String { try String(contentsOf: writeURL, encoding: .utf8) }
    func arguments(_ operation: String) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent(operation + ".args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
    func failWrites() throws { try Data("2".utf8).write(to: directory.appendingPathComponent("write-status")) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
