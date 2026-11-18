import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `StatusBarOverride.overrideArguments` — the
/// argv tail handed to `xcrun simctl status_bar <udid> override …`.
/// The flag spellings here are the contract with simctl; they were
/// verified against `xcrun simctl status_bar … override` help output
/// (see `docs/features/status-bar/README.md`).
@Suite("StatusBarOverride")
struct StatusBarOverrideTests {

    @Test func `should pass no flags when the override sets nothing`() {
        #expect(StatusBarOverride().overrideArguments == [])
    }

    @Test func `should pass battery state and level as paired flags in order`() {
        let o = StatusBarOverride(batteryState: .charged, batteryLevel: 68)
        #expect(o.overrideArguments == ["--batteryState", "charged", "--batteryLevel", "68"])
    }

    @Test func `should pass every flag in a stable order for a full override`() {
        let o = StatusBarOverride(
            time: "9:41",
            operatorName: "Baguette",
            dataNetwork: .fiveG,
            wifiMode: .active,
            wifiBars: 3,
            cellularMode: .active,
            cellularBars: 4,
            batteryState: .charged,
            batteryLevel: 100
        )
        #expect(o.overrideArguments == [
            "--time", "9:41",
            "--operatorName", "Baguette",
            "--dataNetwork", "5g",
            "--wifiMode", "active",
            "--wifiBars", "3",
            "--cellularMode", "active",
            "--cellularBars", "4",
            "--batteryState", "charged",
            "--batteryLevel", "100",
        ])
    }

    @Test func `should spell data networks the way simctl does`() {
        #expect(StatusBarOverride(dataNetwork: .lteA).overrideArguments == ["--dataNetwork", "lte-a"])
        #expect(StatusBarOverride(dataNetwork: .fiveGPlus).overrideArguments == ["--dataNetwork", "5g+"])
        #expect(StatusBarOverride(dataNetwork: .fiveGUWB).overrideArguments == ["--dataNetwork", "5g-uwb"])
        #expect(StatusBarOverride(dataNetwork: .hide).overrideArguments == ["--dataNetwork", "hide"])
    }

    @Test func `should keep the camelCase notSupported spelling for cellular mode`() {
        #expect(StatusBarOverride(cellularMode: .notSupported).overrideArguments
            == ["--cellularMode", "notSupported"])
    }

    @Test func `should clamp wifi bars to 0 through 3`() {
        #expect(StatusBarOverride(wifiBars: 9).overrideArguments == ["--wifiBars", "3"])
        #expect(StatusBarOverride(wifiBars: -2).overrideArguments == ["--wifiBars", "0"])
    }

    @Test func `should clamp cellular bars to 0 through 4`() {
        #expect(StatusBarOverride(cellularBars: 9).overrideArguments == ["--cellularBars", "4"])
    }

    @Test func `should clamp battery level to 0 through 100`() {
        #expect(StatusBarOverride(batteryLevel: 250).overrideArguments == ["--batteryLevel", "100"])
        #expect(StatusBarOverride(batteryLevel: -5).overrideArguments == ["--batteryLevel", "0"])
    }

    @Test func `should still pass an empty operator name so the carrier can be blanked`() {
        #expect(StatusBarOverride(operatorName: "").overrideArguments == ["--operatorName", ""])
    }

    @Test func `should count an override as empty only when no field is set`() {
        #expect(StatusBarOverride().isEmpty)
        #expect(!StatusBarOverride(batteryLevel: 50).isEmpty)
    }
}
