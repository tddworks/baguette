import Testing
import Foundation
@testable import BaguetteCore

/// Pure-value coverage for `StatusBarOverride.overrideArguments` — the
/// argv tail handed to `xcrun simctl status_bar <udid> override …`.
/// The flag spellings here are the contract with simctl; they were
/// verified against `xcrun simctl status_bar … override` help output
/// (see `docs/features/status-bar.md`).
@Suite("StatusBarOverride")
struct StatusBarOverrideTests {

    @Test func `empty override produces no arguments`() {
        #expect(StatusBarOverride().overrideArguments == [])
    }

    @Test func `battery state and level emit paired flags in order`() {
        let o = StatusBarOverride(batteryState: .charged, batteryLevel: 68)
        #expect(o.overrideArguments == ["--batteryState", "charged", "--batteryLevel", "68"])
    }

    @Test func `a full override emits every flag in a stable order`() {
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

    @Test func `data network wire names match simctl spellings`() {
        #expect(StatusBarOverride(dataNetwork: .lteA).overrideArguments == ["--dataNetwork", "lte-a"])
        #expect(StatusBarOverride(dataNetwork: .fiveGPlus).overrideArguments == ["--dataNetwork", "5g+"])
        #expect(StatusBarOverride(dataNetwork: .fiveGUWB).overrideArguments == ["--dataNetwork", "5g-uwb"])
        #expect(StatusBarOverride(dataNetwork: .hide).overrideArguments == ["--dataNetwork", "hide"])
    }

    @Test func `cellular mode notSupported keeps its camelCase wire spelling`() {
        #expect(StatusBarOverride(cellularMode: .notSupported).overrideArguments
            == ["--cellularMode", "notSupported"])
    }

    @Test func `wifi bars clamp to 0 through 3`() {
        #expect(StatusBarOverride(wifiBars: 9).overrideArguments == ["--wifiBars", "3"])
        #expect(StatusBarOverride(wifiBars: -2).overrideArguments == ["--wifiBars", "0"])
    }

    @Test func `cellular bars clamp to 0 through 4`() {
        #expect(StatusBarOverride(cellularBars: 9).overrideArguments == ["--cellularBars", "4"])
    }

    @Test func `battery level clamps to 0 through 100`() {
        #expect(StatusBarOverride(batteryLevel: 250).overrideArguments == ["--batteryLevel", "100"])
        #expect(StatusBarOverride(batteryLevel: -5).overrideArguments == ["--batteryLevel", "0"])
    }

    @Test func `an empty operator name is still emitted so the carrier can be blanked`() {
        #expect(StatusBarOverride(operatorName: "").overrideArguments == ["--operatorName", ""])
    }

    @Test func `isEmpty is true only when no field is set`() {
        #expect(StatusBarOverride().isEmpty)
        #expect(!StatusBarOverride(batteryLevel: 50).isEmpty)
    }
}
