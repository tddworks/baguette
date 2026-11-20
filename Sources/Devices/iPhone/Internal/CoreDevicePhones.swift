import BaguetteDevice
import Foundation

/// The CoreDevice family as a source of `Devices`: the real phones
/// `devicectl list devices` knows. Listing runs devicectl (~0.2 s), and every
/// per-device request asks every source, so a simulator's tap paid it too:
/// the first listing is waited for; for `freshness` after it, the last one
/// answers; after that it still answers at once while a fresh one is read
/// behind (`refresh`), so a phone plugged in shows within a couple of seconds
/// and no request waits on devicectl again. A host where devicectl can't list
/// (no Xcode 15+) has no phones.
final class CoreDevicePhones: Devices, @unchecked Sendable {
    /// Runs work off the caller's thread.
    typealias Refresh = @Sendable (_ work: @escaping @Sendable () -> Void) -> Void

    static let freshness: TimeInterval = 2

    private let devicectl: Devicectl
    private let clock: @Sendable () -> Date
    private let refresh: Refresh
    private let lock = NSLock()
    private let firstLock = NSLock()
    private var listed: (at: Date, phones: [PhysicalPhone])?
    private var refreshing = false

    init(
        devicectl: Devicectl = Devicectl(),
        clock: @escaping @Sendable () -> Date = Date.init,
        refresh: @escaping Refresh = { work in DispatchQueue.global(qos: .utility).async(execute: work) }
    ) {
        self.devicectl = devicectl
        self.clock = clock
        self.refresh = refresh
    }

    var all: [any Device] {
        phones().map { CoreDevicePhone($0, devicectl: devicectl) }
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }

    private func phones() -> [PhysicalPhone] {
        let now = clock()
        let (last, stale) = lock.withLock { () -> ([PhysicalPhone]?, Bool) in
            guard let listed else { return (nil, false) }
            let stale = now.timeIntervalSince(listed.at) >= Self.freshness && !refreshing
            if stale { refreshing = true }
            return (listed.phones, stale)
        }
        guard let last else { return firstListing() }
        if stale {
            refresh { [self] in
                let phones = list()
                lock.withLock {
                    // A failed refresh keeps the last good listing; it is tried again next time.
                    if let phones { listed = (clock(), phones) }
                    refreshing = false
                }
            }
        }
        return last
    }

    /// The first listing, made once however many lookups arrive together.
    private func firstListing() -> [PhysicalPhone] {
        firstLock.withLock {
            if let listed = lock.withLock({ listed }) { return listed.phones }
            let phones = list() ?? []
            lock.withLock { listed = (clock(), phones) }
            return phones
        }
    }

    /// nil when devicectl couldn't list.
    private func list() -> [PhysicalPhone]? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait(["list", "devices", "--quiet", "--json-output", file.path])) != nil,
              let data = try? Data(contentsOf: file),
              let phones = try? PhysicalPhone.list(fromDevicectlJSON: data)
        else { return nil }
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
                   model: phone.marketingName, hardware: phone.productType,
                   os: phone.osVersion.map { "\(phone.platform.rawValue) \($0)" })
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
