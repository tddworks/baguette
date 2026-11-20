import Foundation

/// Cuts one H.264 picture into RTP payloads (RFC 6184, packetization mode 1)
/// for a WebRTC viewer. A NAL unit that fits goes as it is; a bigger one goes as
/// FU-A fragments; the parameter sets ahead of a keyframe go together as one
/// STAP-A. No payload is larger than `maxPayload`, so a packet fits a 1280-byte
/// tunnel (Tailscale, WireGuard) with room for the RTP, SRTP, UDP and IP headers.
public struct H264Packetizer: Equatable, Sendable {
    public static let maxPayload = 1200

    private static let stapA: UInt8 = 24
    private static let fuA: UInt8 = 28

    public init() {}

    /// The picture's payloads, in sending order: `parameterSets` first as one
    /// STAP-A when given, then each NAL unit of `picture` (4-byte lengths, as
    /// the encoder writes AVCC). The caller marks the last one.
    public func payloads(picture: Data, parameterSets: [Data] = []) -> [Data] {
        var out: [Data] = []
        if !parameterSets.isEmpty { out.append(Self.aggregate(parameterSets)) }
        for nal in Self.nalUnits(of: picture) {
            if nal.count <= Self.maxPayload {
                out.append(nal)
            } else {
                out += Self.fragments(of: nal)
            }
        }
        return out
    }

    /// The NAL units behind 4-byte big-endian lengths; a length that runs past
    /// the end stops the read.
    static func nalUnits(of picture: Data) -> [Data] {
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

    /// STAP-A: the highest NRI of its units, type 24, then each unit behind a
    /// 2-byte length.
    private static func aggregate(_ units: [Data]) -> Data {
        let nri = units.map { ($0.first ?? 0) & 0x60 }.max() ?? 0
        var out = Data([nri | stapA])
        for unit in units {
            out.append(contentsOf: [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)])
            out.append(unit)
        }
        return out
    }

    /// FU-A: the NAL's F and NRI with type 28, then a header carrying the start
    /// and end bits and the NAL's own type; the NAL header itself isn't repeated.
    private static func fragments(of nal: Data) -> [Data] {
        let header = nal[nal.startIndex]
        let indicator = header & 0xE0 | fuA
        let type = header & 0x1F
        let body = [UInt8](nal.dropFirst())
        let room = maxPayload - 2
        return stride(from: 0, to: body.count, by: room).map { start in
            let end = min(start + room, body.count)
            let flags: UInt8 = (start == 0 ? 0x80 : 0) | (end == body.count ? 0x40 : 0)
            return Data([indicator, flags | type] + body[start..<end])
        }
    }
}
