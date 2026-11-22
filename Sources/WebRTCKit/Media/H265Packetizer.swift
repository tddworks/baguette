import Foundation

/// Cuts one H.265 picture into RTP payloads (RFC 7798, no DONL: one stream, in
/// order). A NAL unit that fits goes as it is; a bigger one goes as
/// fragmentation units; the parameter sets ahead of a keyframe — VPS, SPS,
/// PPS — go together as one aggregation packet. An H.265 NAL header is two
/// bytes: F (1 bit) · type (6) · layer id (6) · temporal id (3).
public struct H265Packetizer: RTPPacketizer, Equatable {
    public static let maxPayload = 1200

    private static let aggregation: UInt8 = 48
    private static let fragmentation: UInt8 = 49

    public init() {}

    public func payloads(picture: Data, parameterSets: [Data] = []) -> [Data] {
        var out: [Data] = []
        if !parameterSets.isEmpty { out.append(Self.aggregate(parameterSets)) }
        for nal in LengthPrefixedNALUnits.split(picture) {
            if nal.count <= Self.maxPayload {
                out.append(nal)
            } else {
                out += Self.fragments(of: nal)
            }
        }
        return out
    }

    /// Aggregation packet: F the OR of its units', type 48, their lowest layer
    /// id and lowest temporal id; then each unit behind a 2-byte length.
    private static func aggregate(_ units: [Data]) -> Data {
        let headers = units.filter { $0.count >= 2 }.map { ($0[$0.startIndex], $0[$0.startIndex + 1]) }
        let forbidden = headers.reduce(UInt8(0)) { $0 | ($1.0 & 0x80) }
        let layer = headers.map { UInt16($0.0 & 0x01) << 5 | UInt16($0.1 >> 3) }.min() ?? 0
        let temporal = headers.map { $0.1 & 0x07 }.min() ?? 1
        var out = Data([forbidden | aggregation << 1 | UInt8(layer >> 5), UInt8(layer & 0x1F) << 3 | temporal])
        for unit in units {
            out.append(contentsOf: [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)])
            out.append(unit)
        }
        return out
    }

    /// Fragmentation unit: the NAL's header with its type replaced by 49, then
    /// a header carrying the start and end bits and the NAL's own type; the
    /// NAL's 2-byte header itself isn't repeated.
    private static func fragments(of nal: Data) -> [Data] {
        let (first, second) = (nal[nal.startIndex], nal[nal.startIndex + 1])
        let header = [first & 0x81 | fragmentation << 1, second]
        let type = (first >> 1) & 0x3F
        let body = [UInt8](nal.dropFirst(2))
        let room = maxPayload - 3
        return stride(from: 0, to: body.count, by: room).map { start in
            let end = min(start + room, body.count)
            let flags: UInt8 = (start == 0 ? 0x80 : 0) | (end == body.count ? 0x40 : 0)
            return Data(header + [flags | type] + body[start..<end])
        }
    }
}
