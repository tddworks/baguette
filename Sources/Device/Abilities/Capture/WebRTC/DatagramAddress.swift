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
