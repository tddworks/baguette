import CommonCrypto
import Foundation

/// The name and password a TURN server knows its users by (long-term
/// credentials, RFC 8489 §9.2).
public struct TURNCredentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// What signs a request once a server has said who it is: its realm and the
/// nonce it handed out, and the key — MD5("username:realm:password").
public struct TURNAuth: Equatable, Sendable {
    public let credentials: TURNCredentials
    public let realm: String
    public let nonce: String

    public init(credentials: TURNCredentials, realm: String, nonce: String) {
        self.credentials = credentials
        self.realm = realm
        self.nonce = nonce
    }

    public var key: [UInt8] {
        let text = [UInt8]("\(credentials.username):\(realm):\(credentials.password)".utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5(text, CC_LONG(text.count), &digest)
        return digest
    }
}

/// TURN (RFC 8656) as a client writes it: STUN's format, with the methods that
/// get a relayed address on a server (Allocate), keep it (Refresh), let a peer
/// through it (CreatePermission), and carry data to and from that peer (Send
/// and Data indications).
public enum TURNMessage {
    // Message types: method and class (request, success, error, indication).
    static let allocateRequest: UInt16 = 0x0003, allocateSuccess: UInt16 = 0x0103, allocateError: UInt16 = 0x0113
    static let refreshRequest: UInt16 = 0x0004, refreshSuccess: UInt16 = 0x0104, refreshError: UInt16 = 0x0114
    static let createPermissionRequest: UInt16 = 0x0008, createPermissionSuccess: UInt16 = 0x0108
    static let createPermissionError: UInt16 = 0x0118
    static let sendIndication: UInt16 = 0x0016, dataIndication: UInt16 = 0x0017

    // Attributes.
    static let username: UInt16 = 0x0006, messageIntegrity: UInt16 = 0x0008, errorCode: UInt16 = 0x0009
    static let lifetime: UInt16 = 0x000D, xorPeerAddress: UInt16 = 0x0012, data: UInt16 = 0x0013
    static let realm: UInt16 = 0x0014, nonce: UInt16 = 0x0015, xorRelayedAddress: UInt16 = 0x0016
    static let requestedTransport: UInt16 = 0x0019, xorMappedAddress: UInt16 = 0x0020

    /// A relay for UDP, signed once the server has challenged.
    static func allocate(transactionID: [UInt8], auth: TURNAuth?) -> Data {
        signed(allocateRequest, transactionID: transactionID, [(requestedTransport, [17, 0, 0, 0])], auth: auth)
    }

    /// Keep the allocation `lifetime` seconds more; 0 gives it up.
    static func refresh(lifetime seconds: UInt32, transactionID: [UInt8], auth: TURNAuth?) -> Data {
        signed(refreshRequest, transactionID: transactionID, [(lifetime, STUNMessage.bigEndian(seconds))], auth: auth)
    }

    /// Let these peers' datagrams through the relay (permissions last 5 minutes).
    static func createPermission(peers: [DatagramAddress], transactionID: [UInt8], auth: TURNAuth?) -> Data {
        let addresses = peers.map { (xorPeerAddress, xor($0, transactionID: transactionID)) }
        return signed(createPermissionRequest, transactionID: transactionID, addresses, auth: auth)
    }

    /// `payload` for `peer`, sent out of the relay.
    static func send(_ payload: Data, to peer: DatagramAddress, transactionID: [UInt8]) -> Data {
        encode(type: sendIndication, transactionID: transactionID,
               attributes: [(xorPeerAddress, xor(peer, transactionID: transactionID)), (data, [UInt8](payload))])
    }

    /// Any STUN-format message: header, attributes, and — with a key —
    /// MESSAGE-INTEGRITY over all before it.
    static func encode(type: UInt16, transactionID: [UInt8], attributes: [(UInt16, [UInt8])], key: [UInt8]? = nil) -> Data {
        var body = attributes.flatMap { STUNMessage.attribute($0.0, $0.1) }
        let header = { (length: Int) in STUNMessage.header(type, length: length, transactionID: transactionID) }
        if let key { body += STUNMessage.attribute(messageIntegrity, STUNMessage.hmac(header(body.count + 24) + body, key: key)) }
        return Data(header(body.count) + body)
    }

    private static func signed(
        _ type: UInt16, transactionID: [UInt8], _ attributes: [(UInt16, [UInt8])], auth: TURNAuth?
    ) -> Data {
        guard let auth else { return encode(type: type, transactionID: transactionID, attributes: attributes) }
        let identity: [(UInt16, [UInt8])] = [
            (username, [UInt8](auth.credentials.username.utf8)),
            (realm, [UInt8](auth.realm.utf8)), (nonce, [UInt8](auth.nonce.utf8)),
        ]
        return encode(type: type, transactionID: transactionID, attributes: attributes + identity, key: auth.key)
    }

    static func xor(_ address: DatagramAddress, transactionID: [UInt8]) -> [UInt8] {
        let key = STUNMessage.bigEndian(STUNMessage.magicCookie) + transactionID
        let port = address.port ^ UInt16(STUNMessage.magicCookie >> 16)
        return [0, address.isIPv6 ? 2 : 1, UInt8(port >> 8), UInt8(port & 0xFF)] + zip(address.ip, key).map { $0 ^ $1 }
    }
}

/// A TURN message read: whatever a server answered, or a peer's data it
/// relayed — its type and the attributes the client acts on.
public struct TURNReply: Sendable {
    public let type: UInt16
    public let transactionID: [UInt8]
    /// Each attribute's first value, by type.
    let attributes: [UInt16: [UInt8]]
    /// Every XOR-PEER-ADDRESS, in order.
    public let peers: [DatagramAddress]
    private let bytes: [UInt8]
    private let integrityAt: Int?

    /// Nil for bytes that aren't a whole STUN-format message.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0] & 0xC0 == 0, STUNMessage.word(bytes, at: 4) == STUNMessage.magicCookie else { return nil }
        let length = Int(STUNMessage.half(bytes, at: 2))
        guard length % 4 == 0, bytes.count == 20 + length else { return nil }
        let id = Array(bytes[8..<20])
        var attributes: [UInt16: [UInt8]] = [:]
        var peers: [DatagramAddress] = []
        var integrityAt: Int?
        var at = 20
        while at + 4 <= bytes.count {
            let type = STUNMessage.half(bytes, at: at), size = Int(STUNMessage.half(bytes, at: at + 2))
            guard at + 4 + size <= bytes.count else { return nil }
            let value = Array(bytes[at + 4..<at + 4 + size])
            if attributes[type] == nil { attributes[type] = value }
            if type == TURNMessage.xorPeerAddress, let peer = STUNMessage.unmapped(value, transactionID: id) { peers.append(peer) }
            if type == TURNMessage.messageIntegrity, integrityAt == nil { integrityAt = at }
            at += 4 + (size + 3) / 4 * 4
        }
        type = STUNMessage.half(bytes, at: 0)
        transactionID = id
        self.attributes = attributes
        self.peers = peers
        self.bytes = bytes
        self.integrityAt = integrityAt
    }

    /// 401 (unauthorized), 438 (stale nonce), …; nil when it isn't an error.
    public var errorCode: Int? {
        guard let value = attributes[TURNMessage.errorCode], value.count >= 4 else { return nil }
        return Int(value[2] & 0x07) * 100 + Int(value[3])
    }

    public var realm: String? { attributes[TURNMessage.realm].map { String(decoding: $0, as: UTF8.self) } }
    public var nonce: String? { attributes[TURNMessage.nonce].map { String(decoding: $0, as: UTF8.self) } }

    /// The address its allocation relays at.
    public var relayed: DatagramAddress? {
        attributes[TURNMessage.xorRelayedAddress].flatMap { STUNMessage.unmapped($0, transactionID: transactionID) }
    }

    /// Seconds the allocation lasts.
    public var lifetime: UInt32? {
        attributes[TURNMessage.lifetime].flatMap { $0.count == 4 ? STUNMessage.word($0, at: 0) : nil }
    }

    /// What a peer sent through the relay (Data indication), or what goes to one.
    public var data: Data? { attributes[TURNMessage.data].map { Data($0) } }

    /// Whether its MESSAGE-INTEGRITY checks out under `key`.
    public func isSigned(with key: [UInt8]) -> Bool {
        guard let at = integrityAt, at + 24 <= bytes.count else { return false }
        let signed = STUNMessage.withLength(at + 24 - 20, Array(bytes[0..<at]))
        return STUNMessage.same(STUNMessage.hmac(signed, key: key), Array(bytes[at + 4..<at + 24]))
    }
}
