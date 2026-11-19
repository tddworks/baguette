import BaguetteDevice
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
/// family can do: its screen live through CoreDevice (`CoreDeviceScreen`) —
/// or as stills through devicectl (`DevicectlScreen`) on a Mac without
/// CoreDevice — its pasteboard through devicectl, and touches through
/// CoreDevice's Universal HID service. Not orientation: devicectl's
/// `orientation set` exits 0 on a phone and leaves it as its sensors hold it.
/// Apps and location wait on verbs devicectl lacks (a push, a route).
struct CoreDevicePhone: Device {
    private let phone: PhysicalPhone
    private let devicectl: Devicectl
    private let screenRoute: PhoneScreenRoute

    init(_ phone: PhysicalPhone, devicectl: Devicectl,
         screenRoute: PhoneScreenRoute = PhoneScreenRoute(environment: ProcessInfo.processInfo.environment)) {
        self.phone = phone
        self.devicectl = devicectl
        self.screenRoute = screenRoute
    }

    var id: DeviceID { DeviceID(phone.udid) }
    var name: String { phone.name }
    var state: DeviceState { phone.state }
    var kind: DeviceKind {
        DeviceKind(platform: phone.platform, reality: .physical,
                   model: phone.marketingName, hardware: phone.productType)
    }

    var abilities: Abilities {
        let (udid, devicectl) = (phone.udid, devicectl)
        var abilities = Abilities(device: phone.name)
        // One tunnel for every service reached through it.
        let tunnel = CoreDeviceTunnel(devicectl: devicectl)
        if let identifier = phone.coreDeviceIdentifier, CoreDeviceFramework.isAvailable {
            // Live through CoreDevice, turned into pictures by the receiver
            // `PhoneScreenRoute` picks; without CoreDevice, stills.
            let route = screenRoute
            abilities.register(.screen) {
                CoreDeviceScreen(identifier: identifier, devicectl: devicectl, tunnel: tunnel,
                                 makeReceiver: { try route.receiver() })
            }
        } else {
            abilities.register(.screen) { DevicectlScreen(udid: udid, devicectl: devicectl) }
        }
        if let identifier = phone.coreDeviceIdentifier {
            abilities.register(.touch) { DigitizerTouch(digitizer: CoreDeviceDigitizer(identifier: identifier, tunnel: tunnel)) }
            // Its own accessibility service, over the tunnel.
            abilities.register(.accessibility) { RemoteAXAccessibility(identifier: identifier, tunnel: tunnel) }
        }
        abilities.register(.pasteboard) { DevicectlPasteboard(udid: udid, devicectl: devicectl) }
        return abilities
    }
}
