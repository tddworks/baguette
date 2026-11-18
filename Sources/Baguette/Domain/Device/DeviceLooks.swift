import Foundation

/// How a device looks: its chrome, found by its model — a simulator's
/// device type, a phone's marketing name — and, on a foldable, the panel
/// its hinge lights. The same for every kind of device.
extension Device {
    /// The chrome of the panel lit right now, or nil for a model with no
    /// DeviceKit chrome (Apple TV, a phone whose model has no bundled bezel).
    func chrome(in chromes: any Chromes) -> DeviceChromeAssets? {
        chrome(in: chromes, panel: litPanel(in: chromes))
    }

    /// One named panel's chrome, hinge not consulted. Image routes take
    /// the panel from the URL the definition handed out, so a cached
    /// `bezel.png` can never be the other panel's.
    func chrome(in chromes: any Chromes, panel: IntegratedPanel) -> DeviceChromeAssets? {
        switch panel {
        case .primary:   return chromes.assets(forDeviceName: kind.model)
        case .secondary: return chromes.assets(forDeviceName: kind.model, panel: .secondary)
        }
    }

    /// Which of the device's panels the chrome, screen and tap space
    /// describe right now.
    ///
    /// One panel is the only answer on every device but a foldable, and it
    /// is answered from the chrome alone. A foldable asks its hinge — a
    /// guest round-trip — and takes no reading, or no hinge, as folded,
    /// which is how the device boots.
    func litPanel(in chromes: any Chromes) -> IntegratedPanel {
        guard chromes.panels(forDeviceName: kind.model).contains(.secondary) else {
            return .primary
        }
        return (try? abilities.require(.hinge))?.litPanel ?? .primary
    }

    /// The installed 3D model of this device: a phone's by its hardware id
    /// ("iPhone19,7"), else by its model — a simulator's device type, stable
    /// across renames — and last by the name it was given, for a model
    /// definition that only knows that.
    func model3D(in models: any DeviceModels) throws -> InstalledDeviceModel? {
        if let hardware = kind.hardware, let found = try models.match(hardware: hardware) {
            return found
        }
        return try models.match(deviceType: kind.model, deviceName: kind.model)
            ?? models.match(deviceType: kind.model, deviceName: name)
    }
}
