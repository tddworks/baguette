import BaguetteDevice
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
    /// The companion's hello names only the hardware (`iPhone17,2`); its
    /// page borrows a bezel the user picks.
    var kind: DeviceKind { DeviceKind(platform: .iOS, reality: .physical, model: phone.model, hardware: phone.model) }

    var abilities: Abilities {
        var abilities = Abilities(device: phone.name)
        if let hub = screens.find(udid: phone.udid) {
            abilities.register(.screen) { hub.view() }
        }
        return abilities
    }
}
