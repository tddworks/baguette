import Foundation

/// Pure bytes → bytes transform from AVCC framing (4-byte big-endian
/// length + NAL) to Annex B framing (`0x00000001` start code + NAL).
/// `ffmpeg -f h264 -i pipe:` consumes Annex B; the H.264 encoder we
/// already run for `StreamFormat.avcc` produces AVCC. This converter
/// is the bridge so the recorder muxes with `-c copy` (no re-encode).
enum AVCCToAnnexB {

    /// Annex B start code emitted before each NAL.
    static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// Convert one AVCC chunk (one or more length-prefixed NALs) to
    /// Annex B. Truncated tails — bad length, NAL extending past the
    /// buffer — are dropped silently rather than crashing; the
    /// recorder pipe should never bring down the encode loop.
    static func naluPayloads(fromAvcc data: Data) -> Data {
        var out = Data()
        var offset = 0
        let count = data.count
        while offset + 4 <= count {
            let length = Int(readUInt32BE(data, at: offset))
            offset += 4
            if length <= 0 || offset + length > count { return out }
            out.append(startCode)
            out.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return out
    }

    /// Parse a Baguette-shaped avcC parameter-set blob and emit
    /// (SPS + PPS) as Annex B. Returns nil on anything that doesn't
    /// look like the blob `H264Encoder.avcCBlob` produces — caller
    /// should treat that as "no parameter sets emitted yet" and drop
    /// the chunk rather than feed garbage to ffmpeg.
    ///
    /// Layout (ISO/IEC 14496-15 §5.2.4.1, single SPS + single PPS):
    ///   [0]    0x01                      configurationVersion
    ///   [1..3] profile / compat / level  copied from SPS[1..3]
    ///   [4]    0xFC | lengthSizeMinusOne
    ///   [5]    0xE0 | numSPS             (we emit 0xE1, one SPS)
    ///   [6..7] spsSize  (big-endian)
    ///   [8..]  SPS bytes
    ///   [+1]   numPPS
    ///   [+2]   ppsSize  (big-endian)
    ///   [+3..] PPS bytes
    static func parameterSetsAnnexB(fromAvcCBlob blob: Data) -> Data? {
        guard blob.count >= 8, blob[0] == 0x01 else { return nil }
        let spsCount = Int(blob[5] & 0x1F)
        guard spsCount == 1 else { return nil }

        let spsSize = Int(readUInt16BE(blob, at: 6))
        let spsStart = 8
        let spsEnd = spsStart + spsSize
        guard spsEnd + 3 <= blob.count else { return nil }

        let ppsCount = Int(blob[spsEnd])
        guard ppsCount == 1 else { return nil }

        let ppsSize = Int(readUInt16BE(blob, at: spsEnd + 1))
        let ppsStart = spsEnd + 3
        let ppsEnd = ppsStart + ppsSize
        guard ppsEnd <= blob.count else { return nil }

        var out = Data()
        out.append(startCode)
        out.append(blob.subdata(in: spsStart..<spsEnd))
        out.append(startCode)
        out.append(blob.subdata(in: ppsStart..<ppsEnd))
        return out
    }

    // MARK: - byte readers

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return (b0 << 8) | b1
    }
}
