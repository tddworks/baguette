import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Orchestration coverage for `SimctlShake` — argv assembly (delegated
/// to `MotionShake`) + the `Subprocess` exit handshake. The irreducible
/// `xcrun` spawn lives in `HostSubprocess` (integration-only), so every
/// branch here is driven through `MockSubprocess`.
@Suite("SimctlShake")
struct SimctlShakeTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var ran = false
    }

    private func makeShake(exitCode: Int32 = 0, deviceSetPath: String? = nil) -> (SimctlShake, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            captures.ran = true
            captures.executable = exe
            captures.arguments = args
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlShake(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), captures)
    }

    @Test func `should shake the device by running xcrun simctl spawn notifyutil with the UIKit shake notification`() async throws {
        let (shake, captures) = makeShake()
        try await shake.shake()

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == [
            "simctl", "spawn", "U", "notifyutil", "-p",
            "com.apple.UIKit.SimulatorShake",
        ])
    }

    @Test func `should shake the device inside its custom device set when it lives in one`() async throws {
        let (shake, captures) = makeShake(deviceSetPath: "/custom set")
        try await shake.shake()

        #expect(captures.arguments == [
            "simctl", "--set", "/custom set", "spawn", "U", "notifyutil", "-p",
            "com.apple.UIKit.SimulatorShake",
        ])
    }

    @Test func `should fail the shake when simctl exits non-zero`() async {
        let (shake, _) = makeShake(exitCode: 3)
        var caught: ShakeError?
        do {
            try await shake.shake()
        } catch {
            caught = error as? ShakeError
        }
        #expect(caught == .simctlFailed(status: 3))
    }
}
