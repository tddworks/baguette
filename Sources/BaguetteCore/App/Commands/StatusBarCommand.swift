import ArgumentParser
import Foundation

/// `baguette status-bar <override|clear> --udid <UDID> …`
///
/// Overrides the booted simulator's status bar (time, carrier, network,
/// Wi-Fi / cellular signal, battery) or clears every override back to
/// live values. Backed by `xcrun simctl status_bar` — a one-shot
/// subprocess, not the SimulatorHID gesture path. The value-domain
/// projection lives in `Domain/StatusBar/StatusBarOverride.swift`; the
/// spawn is in `Infrastructure/StatusBar/SimctlStatusBar.swift`.
struct StatusBarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-bar",
        abstract: "Override or clear the booted simulator's status bar",
        subcommands: [Override.self, Clear.self]
    )

    /// `baguette status-bar override --udid <UDID> [--time …] [--battery-level …] …`
    struct Override: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "override",
            abstract: "Set one or more status-bar overrides"
        )

        @OptionGroup var options: DeviceOption

        @Option(help: "Fixed clock value, e.g. \"9:41\". An ISO date string also sets the date.")
        var time: String?

        @Option(name: .customLong("operator-name"), help: "Cellular carrier name (\"\" blanks it)")
        var operatorName: String?

        @Option(name: .customLong("data-network"),
                help: "Data network: \(DataNetwork.allValueStrings.joined(separator: " | "))")
        var dataNetwork: DataNetwork?

        @Option(name: .customLong("wifi-mode"),
                help: "Wi-Fi mode: \(WifiMode.allValueStrings.joined(separator: " | "))")
        var wifiMode: WifiMode?

        @Option(name: .customLong("wifi-bars"), help: "Wi-Fi signal bars, 0-3")
        var wifiBars: Int?

        @Option(name: .customLong("cellular-mode"),
                help: "Cellular mode: \(CellularMode.allValueStrings.joined(separator: " | "))")
        var cellularMode: CellularMode?

        @Option(name: .customLong("cellular-bars"), help: "Cellular signal bars, 0-4")
        var cellularBars: Int?

        @Option(name: .customLong("battery-state"),
                help: "Battery state: \(BatteryState.allValueStrings.joined(separator: " | "))")
        var batteryState: BatteryState?

        @Option(name: .customLong("battery-level"), help: "Battery percentage, 0-100")
        var batteryLevel: Int?

        /// The parsed flags as a Domain value — the single mapping the
        /// `run()` path and the parsing tests both exercise.
        var override: StatusBarOverride {
            StatusBarOverride(
                time: time,
                operatorName: operatorName,
                dataNetwork: dataNetwork,
                wifiMode: wifiMode,
                wifiBars: wifiBars,
                cellularMode: cellularMode,
                cellularBars: cellularBars,
                batteryState: batteryState,
                batteryLevel: batteryLevel
            )
        }

        func run() async throws {
            let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
            guard let simulator = simulators.find(udid: options.udid) else {
                log("Device \(options.udid) not found")
                throw ExitCode.failure
            }
            guard !override.isEmpty else {
                log("status-bar override: set at least one field")
                throw ExitCode.failure
            }
            do {
                try await simulator.statusBar().override(override)
            } catch {
                log("status-bar override failed: \(error)")
                throw ExitCode.failure
            }
            log("Set \(simulator.name) status bar")
        }
    }

    /// `baguette status-bar clear --udid <UDID>`
    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Clear every status-bar override"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
            guard let simulator = simulators.find(udid: options.udid) else {
                log("Device \(options.udid) not found")
                throw ExitCode.failure
            }
            do {
                try await simulator.statusBar().clear()
            } catch {
                log("status-bar clear failed: \(error)")
                throw ExitCode.failure
            }
            log("Cleared \(simulator.name) status bar overrides")
        }
    }
}

// MARK: - ArgumentParser conformances
//
// Kept in App so Domain stays free of ArgumentParser. Each delegates to
// the Domain `init(wireName:)` so the CLI and the HTTP route share one
// spelling table.

extension DataNetwork: ExpressibleByArgument {
    public init?(argument: String) { self.init(wireName: argument) }
    public static var allValueStrings: [String] { allCases.map(\.wireName) }
}

extension WifiMode: ExpressibleByArgument {
    public init?(argument: String) { self.init(wireName: argument) }
    public static var allValueStrings: [String] { allCases.map(\.wireName) }
}

extension CellularMode: ExpressibleByArgument {
    public init?(argument: String) { self.init(wireName: argument) }
    public static var allValueStrings: [String] { allCases.map(\.wireName) }
}

extension BatteryState: ExpressibleByArgument {
    public init?(argument: String) { self.init(wireName: argument) }
    public static var allValueStrings: [String] { allCases.map(\.wireName) }
}
