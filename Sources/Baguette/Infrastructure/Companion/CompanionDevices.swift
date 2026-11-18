import Foundation

/// The companion family as a source of `Devices`: each phone whose
/// companion app is connected. It can show its screen once its video
/// has arrived; input waits on the Twin runner.
final class CompanionDevices: Devices, @unchecked Sendable {
    private let phones: any CompanionPhones
    private let screens: TwinScreens

    init(phones: any CompanionPhones, screens: TwinScreens) {
        self.phones = phones
        self.screens = screens
    }

    var all: [any Device] {
        phones.all.map { CompanionDevice(phone: $0, screens: screens) }
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }
}

/// A companion-app phone as a `Device`: the one place deciding what the
/// companion family can do.
struct CompanionDevice: Device {
    let phone: CompanionPhone
    let screens: TwinScreens

    var id: DeviceID { DeviceID(phone.udid) }
    var name: String { phone.name }
    /// Connected means live: the companion only says hello from a running phone.
    var state: DeviceState { .ready }
    var kind: DeviceKind { DeviceKind(platform: .iOS, reality: .physical, model: phone.model) }

    var abilities: AbilityTable {
        var table = AbilityTable(device: phone.name)
        if let hub = screens.find(udid: phone.udid) {
            table.register(.screen) { hub.view() }
        }
        return table
    }
}
