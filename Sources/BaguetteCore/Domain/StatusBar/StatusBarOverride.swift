import Foundation

/// A set of status-bar overrides to apply to a booted simulator. Every
/// field is optional: a caller overrides only the indicators it cares
/// about and leaves the rest at the simulator's live values. Mirrors
/// the flags accepted by `xcrun simctl status_bar <udid> override` —
/// see `docs/features/status-bar.md` for the verified flag surface.
///
/// The value is the unit-testable core of the feature: `overrideArguments`
/// is a pure projection to the argv tail simctl expects, with the
/// numeric fields clamped to the ranges simctl enforces (so a bad
/// slider value can't make the spawn fail). The Infrastructure adapter
/// (`SimctlStatusBar`) just prepends `simctl status_bar <udid> override`
/// and runs it.
public struct StatusBarOverride: Equatable, Sendable {
    /// A fixed clock value. simctl also sets the date when the string
    /// is a valid ISO date; a bare time like `"9:41"` only moves the
    /// clock.
    public var time: String?
    /// Cellular operator/carrier name. The empty string is meaningful
    /// — it blanks the carrier — so it is emitted rather than dropped.
    public var operatorName: String?
    public var dataNetwork: DataNetwork?
    public var wifiMode: WifiMode?
    /// Wi-Fi signal strength, clamped to 0…3 on the wire.
    public var wifiBars: Int?
    public var cellularMode: CellularMode?
    /// Cellular signal strength, clamped to 0…4 on the wire.
    public var cellularBars: Int?
    public var batteryState: BatteryState?
    /// Battery percentage, clamped to 0…100 on the wire.
    public var batteryLevel: Int?

    public init(
        time: String? = nil,
        operatorName: String? = nil,
        dataNetwork: DataNetwork? = nil,
        wifiMode: WifiMode? = nil,
        wifiBars: Int? = nil,
        cellularMode: CellularMode? = nil,
        cellularBars: Int? = nil,
        batteryState: BatteryState? = nil,
        batteryLevel: Int? = nil
    ) {
        self.time = time
        self.operatorName = operatorName
        self.dataNetwork = dataNetwork
        self.wifiMode = wifiMode
        self.wifiBars = wifiBars
        self.cellularMode = cellularMode
        self.cellularBars = cellularBars
        self.batteryState = batteryState
        self.batteryLevel = batteryLevel
    }

    /// True when no field is set — the caller has nothing to apply.
    /// `simctl … override` requires at least one flag, so callers
    /// should treat an empty override as a no-op (or an error).
    public var isEmpty: Bool { overrideArguments.isEmpty }

    /// The argv tail after `simctl status_bar <udid> override`. Flags
    /// appear in a stable order so the output is deterministic and
    /// testable; simctl itself accepts them in any order.
    public var overrideArguments: [String] {
        var args: [String] = []
        if let time { args += ["--time", time] }
        if let operatorName { args += ["--operatorName", operatorName] }
        if let dataNetwork { args += ["--dataNetwork", dataNetwork.wireName] }
        if let wifiMode { args += ["--wifiMode", wifiMode.wireName] }
        if let wifiBars { args += ["--wifiBars", String(clamp(wifiBars, 0, 3))] }
        if let cellularMode { args += ["--cellularMode", cellularMode.wireName] }
        if let cellularBars { args += ["--cellularBars", String(clamp(cellularBars, 0, 4))] }
        if let batteryState { args += ["--batteryState", batteryState.wireName] }
        if let batteryLevel { args += ["--batteryLevel", String(clamp(batteryLevel, 0, 100))] }
        return args
    }

    private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    /// Parse the output of `xcrun simctl status_bar <udid> list` back
    /// into an override, so a UI can read the device's current state
    /// before editing. simctl prints numeric codes, not wire names —
    /// the per-field `init?(listCode:)` tables (captured from Xcode 26,
    /// see `docs/features/status-bar.md`) map them back. Lines that
    /// aren't present leave their fields `nil`; an empty list parses to
    /// an empty override.
    public static func fromListOutput(_ output: String) -> StatusBarOverride {
        var o = StatusBarOverride()
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Time:") {
                let value = line.dropFirst("Time:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { o.time = value }
            } else if line.hasPrefix("Operator Name:") {
                let value = line.dropFirst("Operator Name:".count).trimmingCharacters(in: .whitespaces)
                o.operatorName = value
            } else if line.hasPrefix("DataNetworkType:") {
                if let code = ints(line).first { o.dataNetwork = DataNetwork(listCode: code) }
            } else if line.hasPrefix("WiFi Mode:") {
                let nums = ints(line)
                if nums.count >= 1 { o.wifiMode = WifiMode(listCode: nums[0]) }
                if nums.count >= 2 { o.wifiBars = nums[1] }
            } else if line.hasPrefix("Cell Mode:") {
                let nums = ints(line)
                if nums.count >= 1 { o.cellularMode = CellularMode(listCode: nums[0]) }
                if nums.count >= 2 { o.cellularBars = nums[1] }
            } else if line.hasPrefix("Battery State:") {
                let nums = ints(line)
                if nums.count >= 1 { o.batteryState = BatteryState(listCode: nums[0]) }
                if nums.count >= 2 { o.batteryLevel = nums[1] }
            }
        }
        return o
    }

    /// Extract the integer runs from a line, in order. `"WiFi Mode: 3,
    /// WiFi Bars: 2"` → `[3, 2]`.
    private static func ints(_ line: String) -> [Int] {
        line.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    /// JSON object of the set fields, camelCase keys matching the wire
    /// body the routes accept — so `GET …/status-bar` can hand a reading
    /// straight to the browser panel. Unset fields are omitted; an empty
    /// override is `{}`.
    public var jsonString: String {
        func quote(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:   out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
        var parts: [String] = []
        if let time { parts.append("\"time\":\(quote(time))") }
        if let dataNetwork { parts.append("\"dataNetwork\":\(quote(dataNetwork.wireName))") }
        if let wifiMode { parts.append("\"wifiMode\":\(quote(wifiMode.wireName))") }
        if let wifiBars { parts.append("\"wifiBars\":\(wifiBars)") }
        if let cellularMode { parts.append("\"cellularMode\":\(quote(cellularMode.wireName))") }
        if let cellularBars { parts.append("\"cellularBars\":\(cellularBars)") }
        if let operatorName { parts.append("\"operatorName\":\(quote(operatorName))") }
        if let batteryState { parts.append("\"batteryState\":\(quote(batteryState.wireName))") }
        if let batteryLevel { parts.append("\"batteryLevel\":\(batteryLevel)") }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

/// Cellular data-network indicator. Wire spellings are simctl's
/// `--dataNetwork` values; `hide` removes the indicator entirely.
public enum DataNetwork: String, Sendable, CaseIterable, Equatable {
    case hide
    case wifi
    case threeG  = "3g"
    case fourG   = "4g"
    case lte
    case lteA    = "lte-a"
    case ltePlus = "lte+"
    case fiveG   = "5g"
    case fiveGPlus = "5g+"
    case fiveGUWB  = "5g-uwb"
    case fiveGUC   = "5g-uc"

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }

    /// Map the numeric `DataNetworkType` printed by `simctl status_bar
    /// list` back to a case. Codes captured from Xcode 26.
    public init?(listCode: Int) {
        switch listCode {
        case 0:  self = .hide
        case 1:  self = .wifi
        case 6:  self = .threeG
        case 7:  self = .fourG
        case 8:  self = .lte
        case 9:  self = .lteA
        case 10: self = .ltePlus
        case 11: self = .fiveG
        case 12: self = .fiveGPlus
        case 13: self = .fiveGUWB
        case 14: self = .fiveGUC
        default: return nil
        }
    }
}

/// Wi-Fi connection state shown in the status bar.
public enum WifiMode: String, Sendable, CaseIterable, Equatable {
    case searching
    case failed
    case active

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }

    /// Map the `WiFi Mode` code from `simctl status_bar list`. `0` means
    /// Wi-Fi isn't the active path, so it's treated as unset (`nil`).
    public init?(listCode: Int) {
        switch listCode {
        case 1: self = .searching
        case 2: self = .failed
        case 3: self = .active
        default: return nil
        }
    }
}

/// Cellular connection state shown in the status bar.
public enum CellularMode: String, Sendable, CaseIterable, Equatable {
    case notSupported
    case searching
    case failed
    case active

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }

    /// Map the `Cell Mode` code from `simctl status_bar list`. Unlike
    /// Wi-Fi, `0` is a real value here (`notSupported`).
    public init?(listCode: Int) {
        switch listCode {
        case 0: self = .notSupported
        case 1: self = .searching
        case 2: self = .failed
        case 3: self = .active
        default: return nil
        }
    }
}

/// Battery charging state. simctl renders `charged` and `discharging`
/// identically; both are accepted for parity with the simctl surface.
public enum BatteryState: String, Sendable, CaseIterable, Equatable {
    case charging
    case charged
    case discharging

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }

    /// Map the `Battery State` code from `simctl status_bar list`.
    public init?(listCode: Int) {
        switch listCode {
        case 0: self = .discharging
        case 1: self = .charging
        case 2: self = .charged
        default: return nil
        }
    }
}
