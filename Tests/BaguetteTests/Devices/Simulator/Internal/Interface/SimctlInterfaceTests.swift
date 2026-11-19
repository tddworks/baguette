import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Orchestration coverage for `SimctlInterface` — argv assembly + the
/// `Subprocess` exit handshake. The irreducible `xcrun` spawn lives in
/// `HostSubprocess` (integration-only), so every branch here is driven
/// through `MockSubprocess`.
@Suite("SimctlInterface")
struct SimctlInterfaceTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var ran = false
    }

    private func makeInterface(
        stdout: String = "", exitCode: Int32 = 0, deviceSetPath: String? = nil
    ) -> (SimctlInterface, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.ran = true
            captures.executable = exe
            captures.arguments = args
            if !stdout.isEmpty { onBytes(Data(stdout.utf8)) }
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlInterface(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), captures)
    }

    // MARK: - reading

    @Test func `should read the appearance with simctl ui appearance and no value`() async throws {
        let (interface, captures) = makeInterface(stdout: "dark\n")
        let appearance = try await interface.appearance()

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == ["simctl", "ui", "U", "appearance"])
        #expect(appearance == .dark)
    }

    @Test func `should read and set the interface inside the device's custom device set when it lives in one`() async throws {
        let (interface, captures) = makeInterface(stdout: "dark\n", deviceSetPath: "/custom set")

        _ = try await interface.appearance()
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "ui", "U", "appearance"])
        try await interface.setAppearance(.light)
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "ui", "U", "appearance", "light"])
    }

    @Test func `should read the contrast setting from simctl's answer`() async throws {
        let (interface, captures) = makeInterface(stdout: "enabled\n")
        #expect(try await interface.increaseContrast() == .enabled)
        #expect(captures.arguments == ["simctl", "ui", "U", "increase_contrast"])
    }

    @Test func `should read the content size from simctl's answer`() async throws {
        let (interface, captures) = makeInterface(stdout: "accessibility-large\n")
        #expect(try await interface.contentSize() == .accessibilityLarge)
        #expect(captures.arguments == ["simctl", "ui", "U", "content_size"])
    }

    @Test func `should read a shut-down device as unknown rather than fail`() async throws {
        // simctl answers "unknown" and exits 0 for a device that isn't
        // booted. That's a state to show, not an error to raise.
        let (interface, _) = makeInterface(stdout: "unknown\n")
        #expect(try await interface.appearance() == .unknown)
        #expect(try await interface.contentSize() == .unknown)
    }

    // MARK: - writing

    @Test func `should set the appearance by appending the value to the same verb`() async throws {
        let (interface, captures) = makeInterface()
        try await interface.setAppearance(.dark)
        #expect(captures.arguments == ["simctl", "ui", "U", "appearance", "dark"])
    }

    @Test func `should set the contrast setting by appending the value`() async throws {
        let (interface, captures) = makeInterface()
        try await interface.setIncreaseContrast(.enabled)
        #expect(captures.arguments == ["simctl", "ui", "U", "increase_contrast", "enabled"])
    }

    @Test func `should name the category when setting a content size`() async throws {
        let (interface, captures) = makeInterface()
        try await interface.setContentSize(.size(.accessibilityExtraLarge))
        #expect(captures.arguments == [
            "simctl", "ui", "U", "content_size", "accessibility-extra-large",
        ])
    }

    @Test func `should pass the relative word through when stepping the content size`() async throws {
        let (interface, captures) = makeInterface()
        try await interface.setContentSize(.increment)
        #expect(captures.arguments == ["simctl", "ui", "U", "content_size", "increment"])
    }

    // MARK: - refusals and failures

    @Test func `should refuse to set a read-only appearance before anything is spawned`() async throws {
        // `unknown` is an answer, never an instruction. Catching it here
        // means the error names the real mistake instead of echoing a
        // simctl usage dump.
        let (interface, captures) = makeInterface()
        await #expect(throws: InterfaceError.notSettable("unknown")) {
            try await interface.setAppearance(.unknown)
        }
        #expect(captures.ran == false)
    }

    @Test func `should refuse to set an unsupported contrast the same way`() async throws {
        let (interface, captures) = makeInterface()
        await #expect(throws: InterfaceError.notSettable("unsupported")) {
            try await interface.setIncreaseContrast(.unsupported)
        }
        #expect(captures.ran == false)
    }

    @Test func `should refuse a read-only content size rather than apply it as large`() async throws {
        // The third setter used to fall back to "large" for a state
        // that can only be read, quietly changing the device to a
        // category nobody asked for.
        let (interface, captures) = makeInterface()
        await #expect(throws: InterfaceError.notSettable("unknown")) {
            try await interface.setContentSize(.size(.unknown))
        }
        #expect(captures.ran == false)
    }

    @Test func `should report a non-zero simctl exit with its status`() async throws {
        let (interface, _) = makeInterface(exitCode: 3)
        await #expect(throws: InterfaceError.simctlFailed(status: 3)) {
            try await interface.setAppearance(.dark)
        }
    }

    @Test func `should surface its own error when simctl never starts`() async throws {
        // Distinct from a non-zero exit: the process didn't run at all
        // (missing xcrun, fork failure). The caller shouldn't see this
        // as a device that answered.
        struct SpawnRefused: Error {}
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willThrow(SpawnRefused())
        given(sub).terminate().willReturn()
        let interface = SimctlInterface(udid: "U", subprocess: sub)

        await #expect(throws: SpawnRefused.self) { try await interface.appearance() }
        await #expect(throws: SpawnRefused.self) { try await interface.setAppearance(.dark) }
    }

    @Test func `should report a failed read rather than read it as unknown`() async throws {
        // A spawn that failed is a different thing from a device that
        // answered "unknown", and callers should be able to tell them
        // apart.
        let (interface, _) = makeInterface(stdout: "", exitCode: 1)
        await #expect(throws: InterfaceError.simctlFailed(status: 1)) {
            try await interface.appearance()
        }
    }
}
