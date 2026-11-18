import Foundation

/// The CoreDevice family as a source of `Devices`: the real phones
/// `devicectl list devices` knows. Read fresh on every call (~0.2 s).
/// A host where devicectl can't list (no Xcode 15+) has no phones.
final class CoreDevicePhones: Devices, @unchecked Sendable {
    private let devicectl: Devicectl

    init(devicectl: Devicectl = Devicectl()) {
        self.devicectl = devicectl
    }

    var all: [any Device] {
        phones().map { CoreDevicePhone($0, devicectl: devicectl) }
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }

    private func phones() -> [PhysicalPhone] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait(["list", "devices", "--quiet", "--json-output", file.path])) != nil,
              let data = try? Data(contentsOf: file),
              let phones = try? PhysicalPhone.list(fromDevicectlJSON: data)
        else { return [] }
        return phones
    }
}

/// A real phone as a `Device`. The one place deciding what the CoreDevice
/// family can do: its screen, orientation and pasteboard through devicectl,
/// and touches through CoreDevice's Universal HID service. Apps and
/// location wait on verbs devicectl lacks (a push, a route).
struct CoreDevicePhone: Device {
    private let phone: PhysicalPhone
    private let devicectl: Devicectl

    init(_ phone: PhysicalPhone, devicectl: Devicectl) {
        self.phone = phone
        self.devicectl = devicectl
    }

    var id: DeviceID { DeviceID(phone.udid) }
    var name: String { phone.name }
    var state: DeviceState { phone.state }
    var kind: DeviceKind { DeviceKind(platform: phone.platform, reality: .physical, model: phone.productType) }

    var abilities: AbilityTable {
        let (udid, devicectl) = (phone.udid, devicectl)
        var table = AbilityTable(device: phone.name)
        table.register(.screen) { DevicectlScreen(udid: udid, devicectl: devicectl) }
        if let identifier = phone.coreDeviceIdentifier {
            table.register(.input) { DigitizerInput(digitizer: CoreDeviceDigitizer(identifier: identifier)) }
        }
        table.register(.orientation) { DevicectlOrientation(udid: udid, devicectl: devicectl) }
        table.register(.pasteboard) { DevicectlPasteboard(udid: udid, devicectl: devicectl) }
        return table
    }
}
