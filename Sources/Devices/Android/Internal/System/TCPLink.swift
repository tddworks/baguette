import Foundation

/// An `EmulatorLink` over TCP to 127.0.0.1:<port>, a 20 ms wait per receive.
/// Integration-only.
final class TCPLink: EmulatorLink, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    struct Failure: Error {}

    init(port: Int) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { Darwin.close(fd); throw Failure() }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A write the emulator stops reading gives up after a second.
        var writeTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // A write after the emulator closed its end fails rather than
        // raising SIGPIPE, which would end the whole server without a word.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                guard sent > 0 else { throw Failure() }
                offset += sent
            }
        }
    }

    func receive() throws -> Data? {
        guard !lock.withLock({ closed }) else { throw Failure() }
        let count = recv(fd, &buffer, buffer.count, 0)
        if count > 0 { return Data(buffer[0..<count]) }
        // 0: the emulator closed its end. -1 with EAGAIN: the wait ran out.
        if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { throw Failure() }
        return nil
    }

    /// Ends both directions at once (a waiting `recv` returns), but keeps the
    /// descriptor until the link is gone: closed now, its number could be
    /// reused by another socket while a reader still holds it.
    func close() {
        guard lock.withLock({ defer { closed = true }; return !closed }) else { return }
        shutdown(fd, SHUT_RDWR)
    }

    deinit {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
