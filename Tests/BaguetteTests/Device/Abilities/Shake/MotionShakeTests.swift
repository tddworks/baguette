import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Domain coverage for `MotionShake` — the value that owns the UIKit
/// shake notification name and the `simctl spawn notifyutil` argv that
/// posts it into a booted simulator's guest notify namespace.
@Suite("MotionShake")
struct MotionShakeTests {

    @Test func `should shake by posting the UIKit shake notification into the guest with simctl spawn notifyutil`() {
        let shake = MotionShake()
        #expect(shake.simctlArguments(udid: "ABC-123") == [
            "simctl", "spawn", "ABC-123", "notifyutil", "-p",
            "com.apple.UIKit.SimulatorShake",
        ])
    }

    @Test func `should shake a device inside its custom device set when it lives in one`() {
        let shake = MotionShake()
        #expect(shake.simctlArguments(udid: "ABC-123", deviceSetPath: "/custom set") == [
            "simctl", "--set", "/custom set", "spawn", "ABC-123", "notifyutil", "-p",
            "com.apple.UIKit.SimulatorShake",
        ])
    }

    @Test func `should shake through UIKit's private simulator-shake Darwin notification`() {
        #expect(MotionShake.notificationName == "com.apple.UIKit.SimulatorShake")
    }
}
