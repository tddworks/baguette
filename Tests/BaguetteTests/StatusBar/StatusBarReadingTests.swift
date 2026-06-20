import Testing
import Foundation
@testable import BaguetteCore

/// Coverage for `StatusBarOverride.fromListOutput` — the pure parser
/// that turns `xcrun simctl status_bar <udid> list` output back into a
/// `StatusBarOverride`. The numeric codes here were captured from
/// Xcode 26's simctl (see `docs/features/status-bar.md`); the panel
/// reads the current overrides so its controls reflect the device.
@Suite("StatusBarOverride.fromListOutput")
struct StatusBarReadingTests {

    @Test func `no overrides parses to an empty override`() {
        let output = """
        Current Status Bar Overrides:
        =============================
        """
        #expect(StatusBarOverride.fromListOutput(output).isEmpty)
    }

    @Test func `a wifi reading maps the numeric codes back to wire values`() {
        let output = """
        Current Status Bar Overrides:
        =============================
        Time: 9:41
        DataNetworkType: 1
        WiFi Mode: 3, WiFi Bars: 2
        """
        let o = StatusBarOverride.fromListOutput(output)
        #expect(o.time == "9:41")
        #expect(o.dataNetwork == .wifi)
        #expect(o.wifiMode == .active)
        #expect(o.wifiBars == 2)
        #expect(o.cellularBars == nil)
        #expect(o.batteryLevel == nil)
    }

    @Test func `a cellular reading maps dataNetwork and cellular fields`() {
        let output = """
        Current Status Bar Overrides:
        =============================
        DataNetworkType: 11
        Cell Mode: 1, Cell Bars: 4
        Operator Name: Baguette
        Battery State: 2, Battery Level: 68, Not Charging: 0
        """
        let o = StatusBarOverride.fromListOutput(output)
        #expect(o.dataNetwork == .fiveG)
        #expect(o.cellularMode == .searching)
        #expect(o.cellularBars == 4)
        #expect(o.operatorName == "Baguette")
        #expect(o.batteryState == .charged)
        #expect(o.batteryLevel == 68)
    }

    @Test func `data network codes cover the full simctl table`() {
        func dn(_ code: Int) -> DataNetwork? {
            StatusBarOverride.fromListOutput("DataNetworkType: \(code)").dataNetwork
        }
        #expect(dn(0) == .hide)
        #expect(dn(1) == .wifi)
        #expect(dn(6) == .threeG)
        #expect(dn(7) == .fourG)
        #expect(dn(8) == .lte)
        #expect(dn(9) == .lteA)
        #expect(dn(10) == .ltePlus)
        #expect(dn(11) == .fiveG)
        #expect(dn(12) == .fiveGPlus)
        #expect(dn(13) == .fiveGUWB)
        #expect(dn(14) == .fiveGUC)
    }

    @Test func `battery state codes map discharging charging charged`() {
        func bs(_ code: Int) -> BatteryState? {
            StatusBarOverride.fromListOutput("Battery State: \(code), Battery Level: 50, Not Charging: 0").batteryState
        }
        #expect(bs(0) == .discharging)
        #expect(bs(1) == .charging)
        #expect(bs(2) == .charged)
    }

    @Test func `cellular mode code zero is notSupported`() {
        let o = StatusBarOverride.fromListOutput("Cell Mode: 0, Cell Bars: 1")
        #expect(o.cellularMode == .notSupported)
        #expect(o.cellularBars == 1)
    }

    @Test func `a wifi mode of zero is treated as unset`() {
        // simctl prints "WiFi Mode: 0, WiFi Bars: 0" when Wi-Fi isn't
        // the active path; that's not a real Wi-Fi mode.
        let o = StatusBarOverride.fromListOutput("WiFi Mode: 0, WiFi Bars: 0")
        #expect(o.wifiMode == nil)
    }

    @Test func `jsonString emits only set fields with camelCase keys`() throws {
        let o = StatusBarOverride(dataNetwork: .wifi, wifiBars: 2, batteryLevel: 80)
        let data = Data(o.jsonString.utf8)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["dataNetwork"] as? String == "wifi")
        #expect(dict["wifiBars"] as? Int == 2)
        #expect(dict["batteryLevel"] as? Int == 80)
        #expect(dict["time"] == nil)
        #expect(dict["cellularBars"] == nil)
    }

    @Test func `jsonString of an empty override is empty braces`() {
        #expect(StatusBarOverride().jsonString == "{}")
    }

    @Test func `a list reading round-trips through jsonString`() throws {
        let output = """
        DataNetworkType: 11
        Cell Mode: 3, Cell Bars: 4
        Operator Name: Baguette
        Battery State: 2, Battery Level: 68, Not Charging: 0
        """
        let reading = StatusBarOverride.fromListOutput(output)
        let data = Data(reading.jsonString.utf8)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["dataNetwork"] as? String == "5g")
        #expect(dict["cellularBars"] as? Int == 4)
        #expect(dict["operatorName"] as? String == "Baguette")
        #expect(dict["batteryLevel"] as? Int == 68)
    }
}
