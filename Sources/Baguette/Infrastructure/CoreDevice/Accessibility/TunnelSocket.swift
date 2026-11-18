import Foundation

/// A TCP connection to one of the phone's services over the CoreDevice
/// tunnel (IPv6), every read and write bounded by a deadline.
/// Integration-only: the bytes it carries are read and written by the pure
/// values in `Domain/CoreDevice` (`DTXMessage`, `XPCMessage`, `HTTP2Frame`).
final class TunnelSocket {
    private let fd: Int32

    enum Failure: Error, CustomStringConvertible {
        case connect(String, UInt16, Int32), timedOut, closed

        var description: String {
            switch self {
            case let .connect(host, port, code): "could not connect to [\(host)]:\(port) (\(String(cString: strerror(code))))"
            case .timedOut: "the phone did not answer in time"
            case .closed: "the phone closed the connection"
            }
        }
    }

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connect(host, port, errno) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        inet_pton(AF_INET6, host, &address.sin6_addr)
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw Failure.connect(host, port, code)
        }
    }

    deinit { close(fd) }

    func write(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, data.count - sent, 0) }
            guard count > 0 else { throw Failure.closed }
            sent += count
        }
    }

    /// Exactly `count` bytes, or a failure once `deadline` passes.
    func read(_ count: Int, by deadline: Date) throws -> Data {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 65_536))
        while data.count < count {
            guard try readable(by: deadline) else { throw Failure.timedOut }
            let received = recv(fd, &buffer, min(buffer.count, count - data.count), 0)
            guard received > 0 else { throw Failure.closed }
            data.append(contentsOf: buffer[0..<received])
        }
        return data
    }

    private func readable(by deadline: Date) throws -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&poller, 1, Int32(min(remaining, 3600) * 1000)) > 0
    }
}
