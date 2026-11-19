import BaguetteDevice
import Foundation

/// What `adb devices -l` prints, read as the Android devices it lists: one
/// line each after its header — the serial, adb's state for it, then
/// `key:value` details (`model:Pixel_7`, `usb:1-1`, `transport_id:3`).
///
/// An emulator's serial is `emulator-<port>`; anything else (a USB serial, a
/// Wi-Fi `ip:port` or mDNS name) is a physical device.
enum AdbListing {
    struct Entry: Equatable, Sendable {
        /// adb's name for the device — what `adb -s` takes, and its `DeviceID`.
        let serial: String
        /// Its model, as people write it (`Pixel 7`); the serial when adb
        /// doesn't say (an unauthorized device).
        let name: String
        let reality: DeviceKind.Reality
        let state: DeviceState
        /// adb's `model:` (`Pixel_7`), what a bezel would be found by.
        let model: String
    }

    static func entries(in listing: String) -> [Entry] {
        listing.split(whereSeparator: \.isNewline).dropFirst().compactMap { Self.entry(String($0)) }
    }

    private static func entry(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2 else { return nil }
        let serial = fields[0]
        let details = Dictionary(fields.dropFirst(2).compactMap { field -> (String, String)? in
            guard let colon = field.firstIndex(of: ":") else { return nil }
            return (String(field[..<colon]), String(field[field.index(after: colon)...]))
        }, uniquingKeysWith: { first, _ in first })
        let model = details["model"] ?? ""
        return Entry(
            serial: serial,
            name: model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " "),
            reality: serial.hasPrefix("emulator-") ? .emulated : .physical,
            state: state(fields[1]),
            model: model)
    }

    /// adb's word for a device's state, as baguette's.
    private static func state(_ word: String) -> DeviceState {
        switch word {
        case "device": .ready
        case "unauthorized": .unavailable(reason: "accept the USB debugging prompt on the device")
        case "authorizing", "connecting": .starting
        default: .unavailable(reason: word)
        }
    }
}
