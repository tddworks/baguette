import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// A temporary xcrun records the actual read-modify-write result, including
/// argv, exit status, and separate stdout/stderr across real process captures.
@Suite("SimctlSimulatorInjection")
struct SimctlSimulatorInjectionTests {
    private let camera = "/builds/abc123/VirtualCamera.dylib"
    private let motion = "/builds/def456/BaguetteMotion.dylib"

    @Test func `should read the current injected libraries before writing the merged list when arming`() async throws {
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

    @Test func `should read and write the injected libraries inside the simulator's custom device set when it lives in one`() async throws {
        let fixture = try SimulatorInjectionFixture(deviceSetPath: "/custom set")
        defer { fixture.remove() }
        try fixture.output("")
        try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        #expect(
            try fixture.arguments("getenv") == [
                "simctl", "--set", "/custom set", "spawn", "U", "launchctl", "getenv", "DYLD_INSERT_LIBRARIES",
            ])
        #expect(
            try fixture.arguments("setenv") == [
                "simctl", "--set", "/custom set", "spawn", "U", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", camera,
            ])
    }

    @Test func `should keep a dylib another feature already armed when arming`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output(motion + "\n")
        try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        #expect(try fixture.written() == "\(motion):\(camera)")
    }

    @Test func `should rewrite the injected libraries when disarming leaves another dylib armed`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("\(motion):\(camera)\n")
        try await fixture.injection.disarm(dylibPath: camera, on: fixture.simulator)
        #expect(
            try fixture.arguments("setenv") == [
                "simctl", "spawn", "U", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", motion,
            ])
    }

    @Test func `should unset the injected libraries when disarming the last dylib`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output(camera + "\n")
        try await fixture.injection.disarm(dylibPath: camera, on: fixture.simulator)
        #expect(
            try fixture.arguments("unsetenv") == [
                "simctl", "spawn", "U", "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES",
            ])
    }

    @Test func `should tell whether the simulator would load a given dylib`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("\(motion):\(camera)\n")
        #expect(try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator))
        #expect(
            try await fixture.injection.armed(dylibPath: "/builds/x/VirtualNetwork.dylib", on: fixture.simulator)
                == false)
    }

    @Test func `should list every library the simulator would load into the next app`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("\(motion):\(camera)\n")
        #expect(try await fixture.injection.dylibs(on: fixture.simulator).paths == [motion, camera])
    }

    @Test func `should list no libraries when launchctl confirms the variable is unset`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", status: 1)
        #expect(try await fixture.injection.dylibs(on: fixture.simulator).isEmpty)
    }

    @Test func `should find a dylib armed when an older build of it is injected`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("/builds/OLD/VirtualCamera.dylib\n")
        #expect(try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator))
    }

    @Test func `should find nothing armed when launchctl confirms the variable is unset`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", status: 1)
        #expect(try await fixture.injection.armed(dylibPath: camera, on: fixture.simulator) == false)
    }

    @Test func `should arm only the new dylib when the variable is confirmed unset`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", status: 1)
        try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        #expect(try fixture.written() == camera)
    }

    @Test func `should fail arming when the write fails`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("")
        try fixture.failWrites()
        await #expect(throws: SimctlCapture.Failure.failed(udid: "U", status: 2, output: "")) {
            try await fixture.injection.arm(dylibPath: camera, on: fixture.simulator)
        }
    }
}
