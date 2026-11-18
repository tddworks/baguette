import Foundation

/// A `DatagramSocket` over IPv6 UDP, bound to any port on this Mac, with
/// an 8 MiB receive buffer and a 20 ms wait per receive. Integration-only.
final class UDPSocket: DatagramSocket, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    struct Failure: Error {}

    init() throws {
        fd = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure() }
        var size: Int32 = 8 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = Self.address(in6addr_any, port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw Failure() }
    }

    var port: UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin6_port)
    }

    func receive() -> Data? {
        guard !lock.withLock({ closed }) else { return nil }
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    func send(_ datagram: Data, to host: String, port: UInt16) {
        var phoneAddress = in6_addr()
        inet_pton(AF_INET6, host, &phoneAddress)
        var phone = Self.address(phoneAddress, port: port)
        _ = datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &phone) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    func close() {
        guard lock.withLock({ defer { closed = true }; return !closed }) else { return }
        Darwin.close(fd)
    }

    deinit { close() }

    private static func address(_ host: in6_addr, port: UInt16) -> sockaddr_in6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = host
        return address
    }
}
