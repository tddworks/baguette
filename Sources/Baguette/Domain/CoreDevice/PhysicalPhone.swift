import Foundation

/// A real phone (or iPad, or watch) CoreDevice knows about — read from
/// `xcrun devicectl list devices --json-output`. CoreDevice lists
/// simulators too; only `reality: physical` entries are phones.
struct PhysicalPhone: Equatable, Sendable {
    /// The hardware UDID (`00008160-…`), which `devicectl --device` takes.
    let udid: String
    let name: String
    /// `iPhone19,7` — the key a bezel or 3D model is found by.
    let productType: String
    /// `iPhone 18 Pro Max`.
    let marketingName: String
    let platform: DeviceKind.Platform
    let state: DeviceState
}

extension PhysicalPhone {
    /// The physical devices in `devicectl`'s device list, in its order.
    static func list(fromDevicectlJSON data: Data) throws -> [PhysicalPhone] {
        try JSONDecoder().decode(Listing.self, from: data).result.devices
            .filter { $0.hardwareProperties.reality == "physical" }
            .map(PhysicalPhone.init(entry:))
    }

    private init(entry: Listing.Entry) {
        let hardware = entry.hardwareProperties
        self.init(
            udid: hardware.udid,
            name: entry.deviceProperties.name,
            productType: hardware.productType ?? "",
            marketingName: hardware.marketingName ?? hardware.productType ?? "",
            platform: hardware.platform == "watchOS" ? .watchOS
                : hardware.platform == "tvOS" ? .tvOS
                : hardware.platform == "xrOS" || hardware.platform == "visionOS" ? .visionOS
                : .iOS,
            state: Self.state(of: entry))
    }

    /// Ready means CoreDevice can reach it now: paired, Developer Mode on,
    /// booted, and attached. A `disconnected` tunnel is fine — `devicectl`
    /// opens it on demand; `unavailable` means the phone isn't attached.
    private static func state(of entry: Listing.Entry) -> DeviceState {
        if entry.connectionProperties.pairingState != "paired" {
            return .unavailable(reason: "not paired with this Mac")
        }
        if entry.deviceProperties.developerModeStatus == "disabled" {
            return .unavailable(reason: "Developer Mode is off")
        }
        if entry.connectionProperties.tunnelState == "unavailable" {
            return .unavailable(reason: "not connected")
        }
        if let boot = entry.deviceProperties.bootState, boot != "booted" {
            return .starting
        }
        return .ready
    }
}

private struct Listing: Decodable {
    struct Result: Decodable { let devices: [Entry] }
    struct Entry: Decodable {
        struct Connection: Decodable {
            let pairingState: String?
            let tunnelState: String?
        }
        struct Properties: Decodable {
            let name: String
            let bootState: String?
            let developerModeStatus: String?
        }
        struct Hardware: Decodable {
            let udid: String
            let reality: String?
            let productType: String?
            let marketingName: String?
            let platform: String?
        }
        let connectionProperties: Connection
        let deviceProperties: Properties
        let hardwareProperties: Hardware
    }
    let result: Result
}
