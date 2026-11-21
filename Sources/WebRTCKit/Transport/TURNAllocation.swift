import Foundation

/// A TURN server (RFC 8656) and who to be on it: what relays a viewer's media
/// when nothing more direct gets through. Written as WebRTC writes one —
/// `turn:host[:port][?transport=udp]`, port 3478 by default; UDP only.
public struct TURNServer: Equatable, Sendable {
    public let address: DatagramAddress
    public let credentials: TURNCredentials
    /// As it was written — a browser told to use it resolves the name itself.
    public let url: String

    public init(address: DatagramAddress, credentials: TURNCredentials) {
        self.address = address
        self.credentials = credentials
        url = "turn:\(address.ip.map(String.init).joined(separator: ".")):\(address.port)"
    }

    public init?(url: String, credentials: TURNCredentials, resolve: @Sendable (String) -> [UInt8]?) {
        guard url.hasPrefix("turn:") else { return nil }
        let (target, query) = { () -> (Substring, Substring?) in
            let parts = url.dropFirst(5).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }()
        guard query == nil || query == "transport=udp" else { return nil }
        let parts = target.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count == 2 ? UInt16(parts[1]) : 3478
        guard let port, port > 0 else { return nil }
        let dotted = host.split(separator: ".").compactMap { UInt8($0) }
        guard let ip = dotted.count == 4 ? dotted : resolve(host), ip.count == 4 else { return nil }
        address = DatagramAddress(ip: ip, port: port)
        self.credentials = credentials
        self.url = url
    }
}

/// One request to a TURN server and its reply, matched by transaction id.
protocol TURNExchange: Sendable {
    func ask(_ request: Data, transactionID: [UInt8], timeout: TimeInterval) -> TURNReply?
}

/// A relayed address a TURN server gave: where a browser can reach this
/// viewer through it, for `lifetime` seconds unless refreshed; and the
/// realm and nonce that sign what follows.
public struct TURNAllocation: Equatable, Sendable {
    public let server: TURNServer
    public let relayed: DatagramAddress
    public let lifetime: UInt32
    public let auth: TURNAuth

    /// Allocate on `server` over a socket not relaying yet: an unsigned
    /// request, the server's 401 (its realm and nonce), then the same request
    /// signed. Nil when it turns the credentials down or doesn't answer.
    public static func allocate(on server: TURNServer, through datagrams: any Datagrams, timeout: TimeInterval = 1) -> TURNAllocation? {
        allocate(on: server, exchange: SocketExchange(datagrams: datagrams, server: server.address), timeout: timeout)
    }

    static func allocate(on server: TURNServer, exchange: any TURNExchange, timeout: TimeInterval) -> TURNAllocation? {
        var auth: TURNAuth?
        for _ in 0..<3 {
            let id = Self.transactionID()
            guard let reply = exchange.ask(TURNMessage.allocate(transactionID: id, auth: auth), transactionID: id, timeout: timeout)
            else { return nil }
            if reply.type == TURNMessage.allocateSuccess, let relayed = reply.relayed, let signedBy = auth,
               reply.isSigned(with: signedBy.key) {
                return TURNAllocation(server: server, relayed: relayed, lifetime: reply.lifetime ?? 600, auth: signedBy)
            }
            // 401: who it is; 438: a stale nonce. Either way, sign with what it says now —
            // but a second 401 to a signed request means the credentials are wrong.
            guard let code = reply.errorCode, code == 401 || code == 438, let realm = reply.realm, let nonce = reply.nonce,
                  !(code == 401 && auth != nil) else { return nil }
            auth = TURNAuth(credentials: server.credentials, realm: realm, nonce: nonce)
        }
        return nil
    }

    /// Let `peers` through (for 5 minutes, RFC 8656 §9).
    public func permit(_ peers: [DatagramAddress], through datagrams: any Datagrams, timeout: TimeInterval = 1) -> Bool {
        permit(peers, exchange: SocketExchange(datagrams: datagrams, server: server.address), timeout: timeout)
    }

    func permit(_ peers: [DatagramAddress], exchange: any TURNExchange, timeout: TimeInterval) -> Bool {
        let id = Self.transactionID()
        let request = TURNMessage.createPermission(peers: peers, transactionID: id, auth: auth)
        return exchange.ask(request, transactionID: id, timeout: timeout)?.type == TURNMessage.createPermissionSuccess
    }

    /// Keep it `lifetime` seconds more; 0 gives it up.
    public func refresh(lifetime: UInt32, through datagrams: any Datagrams, timeout: TimeInterval = 1) -> Bool {
        refresh(lifetime: lifetime, exchange: SocketExchange(datagrams: datagrams, server: server.address), timeout: timeout)
    }

    func refresh(lifetime: UInt32, exchange: any TURNExchange, timeout: TimeInterval) -> Bool {
        let id = Self.transactionID()
        let request = TURNMessage.refresh(lifetime: lifetime, transactionID: id, auth: auth)
        return exchange.ask(request, transactionID: id, timeout: timeout)?.type == TURNMessage.refreshSuccess
    }

    static func transactionID() -> [UInt8] { (0..<12).map { _ in UInt8.random(in: 0...255) } }
}

/// The exchange on a socket that isn't relaying yet: it listens on the socket
/// itself for the reply, asking once more halfway through `timeout`.
struct SocketExchange: TURNExchange {
    let datagrams: any Datagrams
    let server: DatagramAddress

    func ask(_ request: Data, transactionID: [UInt8], timeout: TimeInterval) -> TURNReply? {
        let replied = DispatchSemaphore(value: 0)
        let reply = Pending()
        datagrams.onReceive { [server] data, from in
            guard from == server, let message = TURNReply(data), message.transactionID == transactionID,
                  reply.set(message) else { return }
            replied.signal()
        }
        defer { datagrams.onReceive { _, _ in } }
        for _ in 0..<2 {
            datagrams.send(request, to: server)
            if replied.wait(timeout: .now() + timeout / 2) == .success { return reply.value }
        }
        return nil
    }
}

/// The first reply heard, once.
final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TURNReply?
    var value: TURNReply? { lock.withLock { stored } }
    func set(_ reply: TURNReply) -> Bool {
        lock.withLock {
            guard stored == nil else { return false }
            stored = reply
            return true
        }
    }
}
