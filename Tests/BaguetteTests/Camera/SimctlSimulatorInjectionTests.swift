import Testing
import Foundation
import Mockable
@testable import BaguetteCore

@Suite("SimctlSimulatorInjection")
struct SimctlSimulatorInjectionTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
    }

    private func makeInjection(exitCode: Int32 = 0) -> (
        SimctlSimulatorInjection,
        MockSubprocess,
        MockSimulator,
        Captures
    ) {
        let sub = MockSubprocess()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let captures = Captures()
        // Run-the-subprocess: capture argv and fire onExit synchronously
        // with the configured status. Keeps the orchestrator's
        // continuation handshake deterministic in tests.
        given(sub).run(
            executable: .any, arguments: .any,
            onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            captures.executable = exe
            captures.arguments = args
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        let injection = SimctlSimulatorInjection(subprocess: sub)
        return (injection, sub, sim, captures)
    }

    @Test func `arm spawns xcrun simctl launchctl setenv with the dylib path`() async throws {
        let (injection, _, sim, captures) = makeInjection()
        try await injection.arm(dylibPath: "/p/VirtualCamera.dylib", on: sim)

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == [
            "simctl", "spawn", "U",
            "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", "/p/VirtualCamera.dylib",
        ])
    }

    @Test func `disarm spawns xcrun simctl launchctl unsetenv`() async throws {
        let (injection, _, sim, captures) = makeInjection()
        try await injection.disarm(on: sim)

        #expect(captures.arguments == [
            "simctl", "spawn", "U",
            "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES",
        ])
    }

    @Test func `non-zero exit propagates as an injection failure`() async {
        let (injection, _, sim, _) = makeInjection(exitCode: 2)

        var threw = false
        do {
            try await injection.arm(dylibPath: "/p/x.dylib", on: sim)
        } catch {
            threw = true
            #expect((error as? SimulatorInjectionError) == .simctlFailed(status: 2))
        }
        #expect(threw)
    }
}
