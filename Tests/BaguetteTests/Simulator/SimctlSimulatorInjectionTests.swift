import Foundation
import Testing

@testable import Baguette

/// A temporary xcrun records the actual read-modify-write result, including
/// argv, exit status, and separate stdout/stderr across real process captures.
@Suite("SimctlSimulatorInjection")
struct SimctlSimulatorInjectionTests {
    private let camera = "/builds/abc123/VirtualCamera.dylib"
    private let motion = "/builds/def456/BaguetteMotion.dylib"

    @Test func `arm reads the current value before writing the merged one`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("")
        try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        #expect(
            try fixture.arguments("getenv") == [
                "simctl", "spawn", "U", "launchctl", "getenv", "DYLD_INSERT_LIBRARIES",
            ])
        #expect(
            try fixture.arguments("setenv") == [
                "simctl", "spawn", "U", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", camera,
            ])
    }

    @Test func `arm keeps a dylib another feature already armed`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output(motion + "\n")
        try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        #expect(try fixture.written() == "\(motion):\(camera)")
    }

    @Test func `disarm rewrites the value when another dylib is still armed`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("\(motion):\(camera)\n")
        try await fixture.injection.disarm(dylibPath: camera, on: fixture.simulator)
        #expect(
            try fixture.arguments("setenv") == [
                "simctl", "spawn", "U", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", motion,
            ])
    }

    @Test func `disarm unsets the variable once nothing is left`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output(camera + "\n")
        try await fixture.injection.disarm(dylibPath: camera, on: fixture.simulator)
        #expect(
            try fixture.arguments("unsetenv") == [
                "simctl", "spawn", "U", "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES",
            ])
    }

    @Test func `armed reports whether this simulator would load a dylib`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("\(motion):\(camera)\n")
        #expect(try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator))
        #expect(
            try await fixture.injection.armed(dylibPath: "/builds/x/VirtualNetwork.dylib", on: fixture.simulator)
                == false)
    }

    @Test func `armed matches by file name, not by build path`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("/builds/OLD/VirtualCamera.dylib\n")
        #expect(try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator))
    }

    @Test func `armed reports nothing armed when launchctl confirms the variable is unset`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", status: 1)
        #expect(try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator) == false)
    }

    @Test func `treats a confirmed unset variable as nothing armed`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", status: 1)
        try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        #expect(try fixture.written() == camera)
    }

    @Test func `a failed write propagates as an injection failure`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("")
        try fixture.failWrites()
        await #expect(throws: SimctlCapture.Failure.failed(udid: "U", status: 2, output: "")) {
            try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        }
    }
}
