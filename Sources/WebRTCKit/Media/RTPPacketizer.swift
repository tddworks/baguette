import Foundation

/// Cuts one encoded picture into RTP payloads for its codec — RFC 6184 for
/// H.264, RFC 7798 for H.265. The sender holds one by this role, so a codec is
/// a new type, never an edit to the sender. No payload is larger than 1200
/// bytes, so a packet fits a 1280-byte tunnel (Tailscale, WireGuard) with room
/// for the RTP, SRTP, UDP and IP headers.
public protocol RTPPacketizer: Sendable {
    /// The picture's payloads, in sending order: `parameterSets` first, as the
    /// codec aggregates them, then each NAL unit of `picture` (4-byte lengths,
    /// as VideoToolbox writes both codecs). The caller marks the last one.
    func payloads(picture: Data, parameterSets: [Data]) -> [Data]
}

/// The NAL units behind 4-byte big-endian lengths, as an encoder writes either
/// codec; a length that runs past the end stops the read.
enum LengthPrefixedNALUnits {
    static func split(_ picture: Data) -> [Data] {
        let bytes = [UInt8](picture)
        var units: [Data] = []
        var at = 0
        while at + 4 <= bytes.count {
            let length = bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            at += 4
            guard length > 0, at + length <= bytes.count else { break }
            units.append(Data(bytes[at..<at + length]))
            at += length
        }
        return units
    }
}
