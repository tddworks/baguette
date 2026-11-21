import Foundation

/// Where a datagram came from, or goes: an IPv4 (4 bytes) or IPv6 (16 bytes)
/// address and a port. A WebRTC viewer learns its browser's from the first
/// connectivity check, and sends everything there.
public struct DatagramAddress: Hashable, Sendable {
    public let ip: [UInt8]
    public let port: UInt16

    public init(ip: [UInt8], port: UInt16) {
        self.ip = ip
        self.port = port
    }

    public var isIPv6: Bool { ip.count == 16 }
}

extension DatagramAddress: CustomStringConvertible {
    /// `192.168.2.221:59739`, or `[2001:db8:0:0:0:0:0:1]:443`: for the log.
    public var description: String {
        guard isIPv6 else { return ip.map(String.init).joined(separator: ".") + ":\(port)" }
        let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(ip[$0]) << 8 | UInt16(ip[$0 + 1]), radix: 16) }
        return "[\(groups.joined(separator: ":"))]:\(port)"
    }
}
