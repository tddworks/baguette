import Foundation

/// A STUN server (RFC 5389): what tells a socket the address the world sees
/// it at — behind a NAT, the NAT's — so a sender can offer that address to a
/// browser outside its network (a server-reflexive candidate). Written as
/// WebRTC writes one: `stun:host[:port]`, port 3478 by default.
public struct STUNServer: Equatable, Sendable {
    public static let defaultPort: UInt16 = 3478

    public let address: DatagramAddress

    public init(address: DatagramAddress) { self.address = address }

    /// `stun:host[:port]`, its host an IPv4 address or a name `resolve` turns
    /// into one; nil for anything else, or a name that doesn't resolve.
    public init?(url: String, resolve: @Sendable (String) -> [UInt8]?) {
        guard url.hasPrefix("stun:") else { return nil }
        let parts = url.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count == 2 ? UInt16(parts[1]) : Self.defaultPort
        guard let port, port > 0 else { return nil }
        let dotted = host.split(separator: ".").compactMap { UInt8($0) }
        guard let ip = dotted.count == 4 ? dotted : resolve(host), ip.count == 4 else { return nil }
        address = DatagramAddress(ip: ip, port: port)
    }

    /// The address it sees `datagrams` at, asked with a Binding request (and
    /// once more halfway through `timeout`, in case the first was lost); nil
    /// when it doesn't answer in time. Only its own success for this
    /// question counts.
    public func publicAddress(
        through datagrams: any Datagrams, timeout: TimeInterval = 0.5,
        transactionID: [UInt8] = (0..<12).map { _ in UInt8.random(in: 0...255) }
    ) -> DatagramAddress? {
        let answered = DispatchSemaphore(value: 0)
        let seen = Seen()
        datagrams.onReceive { [address] data, from in
            guard from == address, let message = STUNMessage(data), message.transactionID == transactionID,
                  let mapped = message.mappedAddress, seen.set(mapped) else { return }
            answered.signal()
        }
        defer { datagrams.onReceive { _, _ in } }
        let request = STUNMessage.bindingRequest(transactionID: transactionID)
        for _ in 0..<2 {
            datagrams.send(request, to: address)
            if answered.wait(timeout: .now() + timeout / 2) == .success { return seen.value }
        }
        return nil
    }
}

/// The first address heard, once.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var address: DatagramAddress?
    var value: DatagramAddress? { lock.withLock { address } }
    func set(_ new: DatagramAddress) -> Bool {
        lock.withLock {
            guard address == nil else { return false }
            address = new
            return true
        }
    }
}
