import Foundation

/// The Mac's end of the CoreDevice tunnel: its address on the phone's
/// network prefix (the phone is `…::1`, the Mac `…::2`).
enum TunnelAddress {
    static func local(facing phone: String, among addresses: [String]) -> String? {
        let prefix = Self.prefix(phone)
        return addresses.first { $0 != phone && Self.prefix($0) == prefix }
    }

    /// The first 64 bits, as written up to the third group.
    private static func prefix(_ address: String) -> [Substring] {
        Array(address.split(separator: ":", omittingEmptySubsequences: false).prefix(3))
    }
}
