import Foundation

/// What this Mac says about itself to a phone: its model and build, and
/// its IPv6 addresses (one of them on the phone's tunnel). Integration-only.
enum HostNetwork {
    /// This Mac, as a media-stream offer names it.
    static var mac: MediaStreamOffer.Mac {
        MediaStreamOffer.Mac(model: sysctl("hw.model"), build: sysctl("kern.osversion"))
    }

    /// Every IPv6 address on this Mac's interfaces, numeric.
    static func addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        var cursor = interfaces
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                addresses.append(String(cString: host))
            }
            cursor = entry.pointee.ifa_next
        }
        return addresses
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}
