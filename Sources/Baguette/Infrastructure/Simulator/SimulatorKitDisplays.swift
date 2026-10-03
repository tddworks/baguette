import Foundation

/// Production `Displays` — phone and CarPlay planes share one
/// enumerate probe so screen ids stay consistent across resolves.
final class SimulatorKitDisplays: Displays, @unchecked Sendable {
    let phone: any Display
    let carPlay: any Display
    private let udid: String
    private let host: any DeviceHost
    private let hinge: any Hinge
    private let keys: (any DeviceKeys)?
    private let enumerateIO: () throws -> String

    /// `keys` presses a foldable's hardware keys through the guest; a
    /// display with several panels routes buttons there.
    init(
        udid: String, host: any DeviceHost, hinge: any Hinge, keys: (any DeviceKeys)? = nil,
        deviceSetPath: String? = nil
    ) {
        let enumerateIO = { try SimctlCapture.enumerate(udid: udid, deviceSetPath: deviceSetPath) }
        self.udid = udid
        self.host = host
        self.hinge = hinge
        self.keys = keys
        self.enumerateIO = enumerateIO
        self.phone = SimulatorKitDisplay(
            kind: .phone,
            udid: udid,
            host: host,
            enumerateIO: enumerateIO,
            hinge: hinge,
            keys: keys
        )
        self.carPlay = SimulatorKitDisplay(
            kind: .carPlay,
            udid: udid,
            host: host,
            enumerateIO: enumerateIO,
            hinge: hinge
        )
    }

    func panel(_ panel: IntegratedPanel) -> any Display {
        SimulatorKitDisplay(
            kind: .phone,
            udid: udid,
            host: host,
            enumerateIO: enumerateIO,
            hinge: hinge,
            keys: keys,
            pinnedPanel: panel
        )
    }
}
