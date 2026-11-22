import Foundation

/// The VPS/SPS/PPS parameter sets inside an hvcC record (ISO/IEC 14496-15
/// §8.3.3) — what an H.265 sender puts ahead of a keyframe. A pure byte
/// parser; every length is checked against the bytes actually present so a
/// truncated record can never overrun. Other NAL unit arrays (SEI) are skipped.
public struct HVCCParameterSets: Equatable, Sendable {
    public let vps: [Data]
    public let sps: [Data]
    public let pps: [Data]
    /// Bytes in each frame's NALU length prefix (1, 2, or 4).
    public let naluHeaderLength: Int

    /// VPS, then SPS, then PPS — the order a decoder needs them in.
    public var inSendingOrder: [Data] { vps + sps + pps }

    public static func parse(hvcC: Data) -> HVCCParameterSets? {
        let bytes = [UInt8](hvcC)
        var cursor = 0

        func take(_ count: Int) -> [UInt8]? {
            guard cursor + count <= bytes.count else { return nil }
            defer { cursor += count }
            return Array(bytes[cursor..<cursor + count])
        }
        func number(_ two: [UInt8]) -> Int { Int(two[0]) << 8 | Int(two[1]) }

        // configurationVersion … lengthSizeMinusOne: 22 bytes, the last holding the length size.
        guard let header = take(22), header[0] == 1, let arrayCount = take(1) else { return nil }
        var units: [UInt8: [Data]] = [:]
        for _ in 0..<Int(arrayCount[0]) {
            guard let kind = take(1), let count = take(2) else { return nil }
            for _ in 0..<number(count) {
                guard let length = take(2), let body = take(number(length)) else { return nil }
                units[kind[0] & 0x3F, default: []].append(Data(body))
            }
        }
        guard let vps = units[32], let sps = units[33], let pps = units[34] else { return nil }
        return HVCCParameterSets(vps: vps, sps: sps, pps: pps, naluHeaderLength: Int(header[21] & 0x03) + 1)
    }

    public init(vps: [Data], sps: [Data], pps: [Data], naluHeaderLength: Int) {
        self.vps = vps
        self.sps = sps
        self.pps = pps
        self.naluHeaderLength = naluHeaderLength
    }
}
