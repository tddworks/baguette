import Foundation

/// The avcC record (ISO/IEC 14496-15 §5.2.4.1): what an H.264 decoder needs
/// before a stream's first keyframe — its profile, its level, and its one
/// SPS and PPS, each length-prefixed.
public enum AVCDecoderConfigurationRecord {
    /// The record for one SPS and one PPS, or nil when the SPS is too short
    /// to carry its profile, compatibility and level bytes.
    public static func bytes(sps: Data, pps: Data) -> Data? {
        let sps = [UInt8](sps), pps = [UInt8](pps)
        guard sps.count >= 4 else { return nil }
        var record: [UInt8] = [0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1]
        record += [UInt8(sps.count >> 8 & 0xFF), UInt8(sps.count & 0xFF)] + sps
        record += [0x01, UInt8(pps.count >> 8 & 0xFF), UInt8(pps.count & 0xFF)] + pps
        return Data(record)
    }
}
