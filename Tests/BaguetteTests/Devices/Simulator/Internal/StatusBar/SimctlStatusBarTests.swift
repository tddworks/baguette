import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Orchestration coverage for `SimctlStatusBar` — argv assembly +
/// the `Subprocess` exit handshake. The irreducible `xcrun` spawn lives
/// in `HostSubprocess` (integration-only), so every branch here is
/// driven through `MockSubprocess`.
@Suite("SimctlStatusBar")
struct SimctlStatusBarTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var ran = false
    }

    private func makeStatusBar(exitCode: Int32 = 0, deviceSetPath: String? = nil) -> (SimctlStatusBar, Captures) {
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
        return (SimctlStatusBar(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), captures)
    }

    @Test func `should override the status bar through xcrun simctl status_bar override with every set flag`() async throws {
        let (statusBar, captures) = makeStatusBar()
        try await statusBar.override(StatusBarOverride(batteryState: .charged, batteryLevel: 68))

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == [
            "simctl", "status_bar", "U", "override",
            "--batteryState", "charged", "--batteryLevel", "68",
        ])
    }

    @Test func `should override, read and clear the status bar inside the device's custom device set when it lives in one`() async throws {
        let (statusBar, captures) = makeStatusBar(deviceSetPath: "/custom set")

        try await statusBar.override(StatusBarOverride(batteryLevel: 68))
        #expect(captures.arguments == [
            "simctl", "--set", "/custom set", "status_bar", "U", "override", "--batteryLevel", "68",
        ])
        _ = try await statusBar.read()
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "status_bar", "U", "list"])
        try await statusBar.clear()
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "status_bar", "U", "clear"])
    }

    @Test func `should read the current status bar back from simctl status_bar list`() async throws {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.executable = exe
            captures.arguments = args
            onBytes(Data("DataNetworkType: 1\nWiFi Mode: 3, WiFi Bars: 2\n".utf8))
            onExit(0)
        }
        given(sub).terminate().willReturn()
        let statusBar = SimctlStatusBar(udid: "U", subprocess: sub)

        let reading = try await statusBar.read()
        #expect(captures.arguments == ["simctl", "status_bar", "U", "list"])
        #expect(reading.dataNetwork == .wifi)
        #expect(reading.wifiMode == .active)
        #expect(reading.wifiBars == 2)
    }

    @Test func `should clear the status bar through xcrun simctl status_bar clear`() async throws {
        let (statusBar, captures) = makeStatusBar()
        try await statusBar.clear()
        #expect(captures.arguments == ["simctl", "status_bar", "U", "clear"])
    }

    @Test func `should reject an empty override without running simctl`() async {
        let (statusBar, captures) = makeStatusBar()
        var caught: StatusBarError?
        do {
            try await statusBar.override(StatusBarOverride())
        } catch {
            caught = error as? StatusBarError
        }
        #expect(caught == .emptyOverride)
        #expect(captures.ran == false)
    }

    @Test func `should report a status-bar failure when simctl exits non-zero`() async {
        let (statusBar, _) = makeStatusBar(exitCode: 3)
        var caught: StatusBarError?
        do {
            try await statusBar.clear()
        } catch {
            caught = error as? StatusBarError
        }
        #expect(caught == .simctlFailed(status: 3))
    }
}
