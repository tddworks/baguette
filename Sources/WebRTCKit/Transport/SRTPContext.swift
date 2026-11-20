import CommonCrypto
import Foundation

/// One direction's SRTP master key and salt (AES_CM_128_HMAC_SHA1_80:
/// 16 and 14 bytes), as DTLS hands them over.
public struct SRTPKeys: Equatable, Sendable {
    public let masterKey: [UInt8]
    public let masterSalt: [UInt8]

    public init(masterKey: [UInt8], masterSalt: [UInt8]) {
        self.masterKey = masterKey
        self.masterSalt = masterSalt
    }

    /// RFC 5764 §4.2: the 60 bytes exported as "EXTRACTOR-dtls_srtp" are
    /// client key | server key | client salt | server salt. A viewer is the
    /// DTLS server, so the server's are its own (`local`).
    public static func fromDTLS(export: [UInt8]) -> (local: SRTPKeys, remote: SRTPKeys)? {
        guard export.count == 60 else { return nil }
        let client = SRTPKeys(masterKey: Array(export[0..<16]), masterSalt: Array(export[32..<46]))
        let server = SRTPKeys(masterKey: Array(export[16..<32]), masterSalt: Array(export[46..<60]))
        return (server, client)
    }
}

/// The session keys RFC 3711 §4.3 derives from a master key, for RTP (labels
/// 0–2) or RTCP (3–5), with a key derivation rate of 0.
struct SRTPSessionKeys: Equatable, Sendable {
    enum Labels: UInt8 { case rtp = 0, rtcp = 3 }

    let cipherKey: [UInt8]
    let authKey: [UInt8]
    let salt: [UInt8]

    init(_ keys: SRTPKeys, labels: Labels) {
        func derive(_ label: UInt8, _ count: Int) -> [UInt8] {
            var x = keys.masterSalt
            x[7] ^= label   // key_id = label || 48-bit zero index, against the salt's last 7 bytes
            return AESCounter.keystream(key: keys.masterKey, iv: x + [0, 0], count: count)
        }
        cipherKey = derive(labels.rawValue, 16)
        authKey = derive(labels.rawValue + 1, 20)
        salt = derive(labels.rawValue + 2, 14)
    }

    /// RFC 3711 §4.1.1: (salt · 2^16) ⊕ (SSRC · 2^64) ⊕ (index · 2^16).
    func iv(ssrc: UInt32, index: UInt64) -> [UInt8] {
        var iv = salt + [0, 0]
        for i in 0..<4 { iv[4 + i] ^= UInt8(ssrc >> (24 - 8 * i) & 0xFF) }
        for i in 0..<6 { iv[8 + i] ^= UInt8(index >> (40 - 8 * i) & 0xFF) }
        return iv
    }

    /// HMAC-SHA1, cut to the 80-bit tag.
    func tag(_ message: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), authKey, authKey.count, message, message.count, &digest)
        return Array(digest.prefix(10))
    }
}

/// A sender's SRTP (RFC 3711, AES_CM_128_HMAC_SHA1_80): it encrypts and signs
/// every RTP packet it sends, and reads only the browser's RTCP whose signature
/// checks out. A value: each stream's rollover counter is its one state.
public struct SRTPContext: Sendable {
    private let outgoing: SRTPSessionKeys
    private let incoming: SRTPSessionKeys
    /// Each stream's last sequence number and rollover counter: a picture
    /// stream and its resend stream count apart (RFC 3711 §3.3.1).
    private var streams: [UInt32: (last: UInt16, rollover: UInt32)] = [:]

    public init(local: SRTPKeys, remote: SRTPKeys) {
        outgoing = SRTPSessionKeys(local, labels: .rtp)
        incoming = SRTPSessionKeys(remote, labels: .rtcp)
    }

    /// The packet as it goes on the wire: header in the clear, payload
    /// encrypted, then the 10-byte tag over both and the rollover counter.
    public mutating func protect(_ packet: RTPPacket) -> Data {
        var rollover = streams[packet.ssrc]?.rollover ?? 0
        if let last = streams[packet.ssrc]?.last, packet.sequence < last, last - packet.sequence > 0x8000 { rollover &+= 1 }
        streams[packet.ssrc] = (packet.sequence, rollover)
        let index = UInt64(rollover) << 16 | UInt64(packet.sequence)
        let wire = [UInt8](packet.data)
        let header = Array(wire.prefix(wire.count - packet.payload.count))
        let sealed = AESCounter.apply(
            key: outgoing.cipherKey, iv: outgoing.iv(ssrc: packet.ssrc, index: index), to: [UInt8](packet.payload))
        let roc = (0..<4).map { UInt8(rollover >> (24 - 8 * $0) & 0xFF) }
        return Data(header + sealed + outgoing.tag(header + sealed + roc))
    }

    /// The browser's RTCP in the clear, or nil when it isn't encrypted SRTCP
    /// signed with its key: 8 bytes of header, the encrypted rest, E-flag and
    /// index, then the tag (RFC 3711 §3.4).
    public func unprotectRTCP(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 + 4 + 10 else { return nil }
        let signed = Array(bytes.prefix(bytes.count - 10))
        let tag = Array(bytes.suffix(10))
        guard zip(incoming.tag(signed), tag).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        let trailer = signed.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // SRTCP lets a sender leave its reports unencrypted (E-flag clear); browsers
        // never do, and a viewer takes only what it would expect from one.
        guard trailer & 0x8000_0000 != 0 else { return nil }
        let body = Array(signed[8..<(signed.count - 4)])
        let ssrc = bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let iv = incoming.iv(ssrc: ssrc, index: UInt64(trailer & 0x7FFF_FFFF))
        return Data(signed.prefix(8) + AESCounter.apply(key: incoming.cipherKey, iv: iv, to: body))
    }
}

/// AES-128 in counter mode, big-endian counter: SRTP's cipher and its key
/// derivation function.
enum AESCounter {
    static func keystream(key: [UInt8], iv: [UInt8], count: Int) -> [UInt8] {
        apply(key: key, iv: iv, to: [UInt8](repeating: 0, count: count))
    }

    static func apply(key: [UInt8], iv: [UInt8], to input: [UInt8]) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        var cryptor: CCCryptorRef?
        CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            iv, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        return output
    }
}
