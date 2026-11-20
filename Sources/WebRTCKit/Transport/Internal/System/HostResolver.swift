import Darwin
import Foundation

/// A host name's first IPv4 address, from the system resolver — for a STUN
/// server written by name (`stun:stun.example.com`).
public enum HostResolver {
    public static func ipv4(_ host: String) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return nil }
        defer { freeaddrinfo(found) }
        guard let address = first.pointee.ai_addr else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
        }
    }
}
