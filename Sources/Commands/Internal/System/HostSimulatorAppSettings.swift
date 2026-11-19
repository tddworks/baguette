import Foundation

/// This Mac's Simulator.app settings, through its preferences domain.
extension SimulatorAppSettings {
    static let host = SimulatorAppSettings(
        lifetime: { SimulatorAppPreferences.lifetime() },
        write: { try SimulatorAppPreferences.write($0) },
        appRunning: { SimulatorAppPreferences.simulatorAppIsRunning }
    )
}
