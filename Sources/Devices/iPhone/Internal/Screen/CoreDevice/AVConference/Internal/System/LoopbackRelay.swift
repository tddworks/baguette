import Foundation

/// Two IPv4 loopback UDP sockets connected to each other: AVConference
/// receives on one (`avconferenceEnd`, handed over by descriptor), baguette
/// on the other. Given the tunnel's IPv6 socket instead, AVConference's
/// RTCP fails and its stream stalls; the loopback relay is device-hub-ios's
/// shape and runs whole sessions. Integration-only.
final class LoopbackRelay: @unchecked Sendable {
    let avconferenceEnd: Int32
    private let ours: Int32
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    init() throws {
        let (first, firstAddress) = try Self.bound()
        let (second, secondAddress) = try Self.bound()
        guard Self.connect(first, to: secondAddress), Self.connect(second, to: firstAddress) else {
            Darwin.close(first); Darwin.close(second)
            throw AVConferenceRefusal(step: "the loopback relay", error: nil)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        setsockopt(second, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        avconferenceEnd = first
        ours = second
    }

    /// One datagram from the phone, to AVConference.
    func deliver(_ datagram: Data) {
        _ = datagram.withUnsafeBytes { Darwin.send(ours, $0.baseAddress, $0.count, 0) }
    }

    /// AVConference's next datagram for the phone, or nil within 20 ms.
    func nextReport() -> Data? {
        let count = recv(ours, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    func close() {
        Darwin.close(ours)
        Darwin.close(avconferenceEnd)
    }

    private static func bound() throws -> (Int32, sockaddr_in) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard fd >= 0, ok else { if fd >= 0 { Darwin.close(fd) }; throw AVConferenceRefusal(step: "the loopback relay", error: nil) }
        return (fd, address)
    }

    private static func connect(_ fd: Int32, to address: sockaddr_in) -> Bool {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
