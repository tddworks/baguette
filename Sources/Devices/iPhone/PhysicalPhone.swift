import BaguetteDevice
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
    /// CoreDevice's own identifier for the phone (`30546CC9-…`), which its
    /// framework API takes where devicectl takes the UDID.
    let coreDeviceIdentifier: UUID?
    /// The phone's end of the CoreDevice tunnel (`…::1`), while it is up.
    var tunnelAddress: String? = nil
    /// The system version devicectl reports ("27.0.1").
    var osVersion: String? = nil
}

extension PhysicalPhone {
    /// The size in pixels of the phone's own screen — its primary display's
    /// `nativeSize` in `devicectl device info displays`. The phone's stream
    /// pads its pictures past this (1320 × 2868 arrives as 1328 × 2896) and
    /// doesn't say so; this is what a picture is cropped back to.
    static func screenPixels(fromDisplaysJSON data: Data) -> Size? {
        struct Info: Decodable {
            struct Result: Decodable { let displays: [Display] }
            struct Display: Decodable { let primary: Bool?; let nativeSize: [Double]? }
            let result: Result
        }
        guard let info = try? JSONDecoder().decode(Info.self, from: data),
              let size = info.result.displays.first(where: { $0.primary == true })?.nativeSize,
              size.count == 2, size[0] > 0, size[1] > 0
        else { return nil }
        return Size(width: size[0], height: size[1])
    }

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
            state: Self.state(of: entry),
            coreDeviceIdentifier: entry.identifier.flatMap(UUID.init(uuidString:)),
            tunnelAddress: entry.connectionProperties.tunnelIPAddress,
            osVersion: entry.deviceProperties.osVersionNumber)
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
            let tunnelIPAddress: String?
        }
        struct Properties: Decodable {
            let name: String
            let bootState: String?
            let developerModeStatus: String?
            let osVersionNumber: String?
        }
        struct Hardware: Decodable {
            let udid: String
            let reality: String?
            let productType: String?
            let marketingName: String?
            let platform: String?
        }
        let identifier: String?
        let connectionProperties: Connection
        let deviceProperties: Properties
        let hardwareProperties: Hardware
    }
    let result: Result
}
