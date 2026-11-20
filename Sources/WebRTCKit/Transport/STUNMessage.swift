import CommonCrypto
import Foundation

/// A STUN message (RFC 5389) as ICE uses it: the browser's connectivity check,
/// and the answer a WebRTC viewer — an ICE-lite agent — sends back. Only a
/// Binding request addressed to the viewer's username fragment and signed with
/// its ICE password is answered (RFC 8445 §7.3); anything else is ignored,
/// never answered with an error.
public struct STUNMessage: Equatable, Sendable {
    static let magicCookie: UInt32 = 0x2112_A442
    private static let bindingRequest: UInt16 = 0x0001
    private static let bindingSuccess: UInt16 = 0x0101
    private static let username: UInt16 = 0x0006
    private static let messageIntegrity: UInt16 = 0x0008
    private static let xorMappedAddress: UInt16 = 0x0020
    private static let fingerprint: UInt16 = 0x8028

    public let type: UInt16
    public let transactionID: [UInt8]
    /// "<our ufrag>:<the browser's ufrag>" on a check.
    public let username: String?
    /// The message as it arrived: its integrity is over these bytes.
    private let bytes: [UInt8]
    /// Where MESSAGE-INTEGRITY starts, when there is one.
    private let integrityAt: Int?

    public var isBindingRequest: Bool { type == Self.bindingRequest }

    /// RFC 7983: on a port shared with DTLS and RTP, STUN's first byte is 0–3.
    public static func isSTUN(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first <= 3
    }

    /// Nil for bytes that aren't a whole STUN message.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0] & 0xC0 == 0,
              Self.word(bytes, at: 4) == Self.magicCookie else { return nil }
        let length = Int(Self.half(bytes, at: 2))
        guard length % 4 == 0, bytes.count == 20 + length else { return nil }
        var username: String?
        var integrityAt: Int?
        var at = 20
        while at + 4 <= bytes.count {
            let type = Self.half(bytes, at: at), size = Int(Self.half(bytes, at: at + 2))
            guard at + 4 + size <= bytes.count else { return nil }
            if type == Self.username { username = String(decoding: bytes[at + 4..<at + 4 + size], as: UTF8.self) }
            if type == Self.messageIntegrity, size == 20, integrityAt == nil { integrityAt = at }
            at += 4 + (size + 3) / 4 * 4
        }
        self.type = Self.half(bytes, at: 0)
        self.transactionID = Array(bytes[8..<20])
        self.username = username
        self.bytes = bytes
        self.integrityAt = integrityAt
    }

    /// The Binding success for this check, telling the browser the address it
    /// came `from` — or nil when this isn't a check for `ice`: its username
    /// "<our ufrag>:<theirs>", its integrity our password.
    public func answer(from address: DatagramAddress, ice: ICECredentials) -> Data? {
        guard isBindingRequest, let at = integrityAt,
              username?.split(separator: ":").first.map(String.init) == ice.ufrag else { return nil }
        let password = ice.password
        // The integrity covers the header and attributes before it, with the
        // length counting through MESSAGE-INTEGRITY itself (RFC 5389 §15.4).
        let signed = Self.withLength(at + 24 - 20, Array(bytes[0..<at]))
        guard Self.same(Self.hmac(signed, key: password), Array(bytes[at + 4..<at + 24])) else { return nil }

        var body = Self.mapped(address, transactionID: transactionID)
        let header = { (length: Int) in Self.header(Self.bindingSuccess, length: length, transactionID: self.transactionID) }
        let integrity = Self.hmac(header(body.count + 24) + body, key: password)
        body += Self.attribute(Self.messageIntegrity, integrity)
        let crc = Self.crc32(header(body.count + 8) + body) ^ 0x5354_554E
        body += Self.attribute(Self.fingerprint, Self.bigEndian(crc))
        return Data(header(body.count) + body)
    }

    // MARK: - wire

    private static func mapped(_ address: DatagramAddress, transactionID: [UInt8]) -> [UInt8] {
        let key = bigEndian(magicCookie) + transactionID
        let port = address.port ^ UInt16(magicCookie >> 16)
        let ip = zip(address.ip, key).map { $0 ^ $1 }
        return attribute(xorMappedAddress, [0, address.isIPv6 ? 2 : 1, UInt8(port >> 8), UInt8(port & 0xFF)] + ip)
    }

    private static func header(_ type: UInt16, length: Int, transactionID: [UInt8]) -> [UInt8] {
        [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(length >> 8), UInt8(length & 0xFF)]
            + bigEndian(magicCookie) + transactionID
    }

    private static func attribute(_ type: UInt16, _ value: [UInt8]) -> [UInt8] {
        let padding = [UInt8](repeating: 0, count: (4 - value.count % 4) % 4)
        return [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value + padding
    }

    private static func withLength(_ length: Int, _ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        out[2] = UInt8(length >> 8)
        out[3] = UInt8(length & 0xFF)
        return out
    }

    private static func hmac(_ message: [UInt8], key: String) -> [UInt8] {
        let key = [UInt8](key.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, message, message.count, &digest)
        return digest
    }

    /// Compared in full, whatever differs first: no timing hint for a forger.
    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func half(_ bytes: [UInt8], at i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }

    private static func word(_ bytes: [UInt8], at i: Int) -> UInt32 {
        bytes[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
