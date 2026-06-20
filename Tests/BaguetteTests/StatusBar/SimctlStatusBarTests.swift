import Testing
import Foundation
import Mockable
@testable import BaguetteCore

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

    private func makeStatusBar(exitCode: Int32 = 0) -> (SimctlStatusBar, Captures) {
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
        return (SimctlStatusBar(udid: "U", subprocess: sub), captures)
    }

    @Test func `override spawns xcrun simctl status_bar override with the projected argv`() async throws {
        let (statusBar, captures) = makeStatusBar()
        try await statusBar.override(StatusBarOverride(batteryState: .charged, batteryLevel: 68))

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == [
            "simctl", "status_bar", "U", "override",
            "--batteryState", "charged", "--batteryLevel", "68",
        ])
    }

    @Test func `read runs simctl status_bar list and parses the output`() async throws {
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

    @Test func `clear spawns xcrun simctl status_bar clear`() async throws {
        let (statusBar, captures) = makeStatusBar()
        try await statusBar.clear()
        #expect(captures.arguments == ["simctl", "status_bar", "U", "clear"])
    }

    @Test func `an empty override throws without spawning anything`() async {
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

    @Test func `a non-zero simctl exit propagates as a status-bar failure`() async {
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
