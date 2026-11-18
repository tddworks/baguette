import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the status-bar routes. As with the
/// orientation route, we test the pure parse + dispatch helpers
/// (`parseStatusBarOverride`, `applyStatusBar`, `clearStatusBar`)
/// rather than the Hummingbird `Response` wrappers — every branch is
/// driven with one device's `MockStatusBar`.
@Suite("Server status-bar routes")
struct StatusBarRoutesTests {

    // MARK: - parse

    @Test func `should read every status-bar field from a JSON body`() {
        let json = """
        {"time":"9:41","operatorName":"Baguette","dataNetwork":"5g",
         "wifiMode":"active","wifiBars":3,"cellularMode":"active",
         "cellularBars":4,"batteryState":"charged","batteryLevel":68}
        """
        #expect(Server.parseStatusBarOverride(json: json) == StatusBarOverride(
            time: "9:41", operatorName: "Baguette", dataNetwork: .fiveG,
            wifiMode: .active, wifiBars: 3, cellularMode: .active,
            cellularBars: 4, batteryState: .charged, batteryLevel: 68
        ))
    }

    @Test func `should read no status-bar override from malformed JSON`() {
        #expect(Server.parseStatusBarOverride(json: "not json") == nil)
    }

    @Test func `should read no status-bar override when an enum field is unrecognised`() {
        #expect(Server.parseStatusBarOverride(json: #"{"dataNetwork":"6g"}"#) == nil)
    }

    @Test func `should accept a partial status-bar body`() {
        #expect(Server.parseStatusBarOverride(json: #"{"batteryLevel":20}"#)
            == StatusBarOverride(batteryLevel: 20))
    }

    // MARK: - apply

    @Test func `should override the device's status bar with the posted fields`() async {
        let statusBar = MockStatusBar()
        let host = routeDevices { $0.register(.statusBar) { statusBar } }
        given(statusBar).override(.any).willReturn(())

        let outcome = await Server.applyStatusBar(
            udid: "U", body: #"{"batteryLevel":50}"#, devices: host
        )
        #expect(outcome == .ok)
        verify(statusBar).override(.value(StatusBarOverride(batteryLevel: 50))).called(1)
    }

    @Test func `should report an unknown device when overriding the status bar of a missing device`() async {
        let host = routeDevices()
        let outcome = await Server.applyStatusBar(
            udid: "ghost", body: #"{"batteryLevel":50}"#, devices: host
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report an invalid body when the status-bar override is malformed JSON`() async {
        let host = routeDevices { $0.register(.statusBar) { MockStatusBar() } }
        let outcome = await Server.applyStatusBar(udid: "U", body: "{", devices: host)
        #expect(outcome == .invalidBody)
    }

    @Test func `should report an empty override when no status-bar field is set`() async {
        let host = routeDevices { $0.register(.statusBar) { MockStatusBar() } }
        let outcome = await Server.applyStatusBar(udid: "U", body: "{}", devices: host)
        #expect(outcome == .emptyOverride)
    }

    @Test func `should report a failed dispatch when simctl cannot override the status bar`() async {
        let statusBar = MockStatusBar()
        let host = routeDevices { $0.register(.statusBar) { statusBar } }
        given(statusBar).override(.any).willThrow(StatusBarError.simctlFailed(status: 1))

        let outcome = await Server.applyStatusBar(
            udid: "U", body: #"{"batteryLevel":50}"#, devices: host
        )
        #expect(outcome == .dispatchFailed)
    }

    // MARK: - clear

    @Test func `should clear the device's status-bar overrides`() async {
        let statusBar = MockStatusBar()
        let host = routeDevices { $0.register(.statusBar) { statusBar } }
        given(statusBar).clear().willReturn(())

        #expect(await Server.clearStatusBar(udid: "U", devices: host) == .ok)
        verify(statusBar).clear().called(1)
    }

    @Test func `should report an unknown device when clearing the status bar for an empty udid`() async {
        let host = routeDevices()
        #expect(await Server.clearStatusBar(udid: "", devices: host) == .unknownDevice)
    }

    // MARK: - read

    @Test func `should read the device's current status-bar overrides`() async {
        let statusBar = MockStatusBar()
        let host = routeDevices { $0.register(.statusBar) { statusBar } }
        given(statusBar).read().willReturn(StatusBarOverride(dataNetwork: .wifi, wifiBars: 2))

        #expect(await Server.readStatusBar(udid: "U", devices: host)
            == .ok(StatusBarOverride(dataNetwork: .wifi, wifiBars: 2)))
    }

    @Test func `should report an unknown device when reading the status bar for an empty udid`() async {
        let host = routeDevices()
        #expect(await Server.readStatusBar(udid: "", devices: host) == .unknownDevice)
    }

    @Test func `should report a failure when the status bar cannot be read`() async {
        let statusBar = MockStatusBar()
        let host = routeDevices { $0.register(.statusBar) { statusBar } }
        given(statusBar).read().willThrow(StatusBarError.simctlFailed(status: 1))

        #expect(await Server.readStatusBar(udid: "U", devices: host) == .failed)
    }
}
