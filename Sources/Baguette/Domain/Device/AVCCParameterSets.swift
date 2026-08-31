import Foundation

/// The SPS/PPS parameter sets inside an avcC configuration blob
/// (ISO/IEC 14496-15 §5.3.3.1) — the description the companion's
/// encoder emits and `VTDecompressionSession` wants back as separate
/// NALUs. A pure byte parser; every length is checked against the
/// bytes actually present so a truncated blob can never overrun.
struct AVCCParameterSets: Equatable, Sendable {
    let sps: [Data]
    let pps: [Data]
    /// Bytes in each frame's NALU length prefix (1, 2, or 4).
    let naluHeaderLength: Int

    static func parse(avcC: Data) -> AVCCParameterSets? {
        let bytes = [UInt8](avcC)
        var cursor = 0

        func take(_ count: Int) -> [UInt8]? {
            guard cursor + count <= bytes.count else { return nil }
            defer { cursor += count }
            return Array(bytes[cursor..<cursor + count])
        }

        // configurationVersion, profile, compatibility, level.
        guard let header = take(4), header[0] == 1 else { return nil }
        guard let lengthByte = take(1) else { return nil }
        let naluHeaderLength = Int(lengthByte[0] & 0x03) + 1

        func parameterSets(count: Int) -> [Data]? {
            var sets: [Data] = []
            for _ in 0..<count {
                guard let lengthBytes = take(2) else { return nil }
                let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
                guard let body = take(length) else { return nil }
                sets.append(Data(body))
            }
            return sets
        }

        guard let spsCountByte = take(1),
              let sps = parameterSets(count: Int(spsCountByte[0] & 0x1F)),
              !sps.isEmpty,
              let ppsCountByte = take(1),
              let pps = parameterSets(count: Int(ppsCountByte[0])),
              !pps.isEmpty else { return nil }

        return AVCCParameterSets(sps: sps, pps: pps, naluHeaderLength: naluHeaderLength)
    }
}
