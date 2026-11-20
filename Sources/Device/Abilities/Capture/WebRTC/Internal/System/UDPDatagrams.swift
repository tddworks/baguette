import Darwin
import Foundation

/// The `Datagrams` a viewer runs: one IPv4 UDP socket on an ephemeral port,
/// bound on every interface, read on its own queue.
public final class UDPDatagrams: Datagrams, @unchecked Sendable {
    private let descriptor: Int32
    private let port: UInt16
    private let queue = DispatchQueue(label: "baguette.webrtc.datagrams")
    private let reader: DispatchSourceRead
    private let lock = NSLock()
    private var handler: (@Sendable (Data, DatagramAddress) -> Void)?

    struct Failure: Error { let step: String; let code: Int32 }

    public init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure(step: "socket", code: errno) }
        var any = sockaddr_in()
        any.sin_family = sa_family_t(AF_INET)
        any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &any) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { Darwin.close(fd); throw Failure(step: "bind", code: errno) }
        descriptor = fd
        port = UInt16(bigEndian: any.sin_port)
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setCancelHandler { Darwin.close(fd) }
        reader.setEventHandler { [weak self] in self?.read() }
        reader.resume()
    }

    /// Every up interface's IPv4 address, at this socket's port.
    public var addresses: [DatagramAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        return sequence(first: list, next: { $0?.pointee.ifa_next }).compactMap { entry in
            guard let entry, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { return nil }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return DatagramAddress(ip: withUnsafeBytes(of: ipv4) { Array($0) }, port: port)
        }
    }

    public func send(_ datagram: Data, to address: DatagramAddress) {
        guard address.ip.count == 4 else { return }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_port = address.port.bigEndian
        withUnsafeMutableBytes(of: &target.sin_addr) { $0.copyBytes(from: address.ip) }
        datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func onReceive(_ handler: @escaping @Sendable (Data, DatagramAddress) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func close() { reader.cancel() }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0, let handler = lock.withLock({ self.handler }) else { return }
        let ip = withUnsafeBytes(of: from.sin_addr.s_addr) { Array($0) }
        handler(Data(buffer.prefix(count)), DatagramAddress(ip: ip, port: UInt16(bigEndian: from.sin_port)))
    }
}
