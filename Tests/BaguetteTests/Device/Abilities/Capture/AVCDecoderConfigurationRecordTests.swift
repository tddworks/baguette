import Foundation
import Testing
@testable import BaguetteDevice

/// The avcC record a decoder needs before an H.264 stream's first keyframe
/// (ISO/IEC 14496-15 §5.2.4.1), written from the stream's SPS and PPS.
@Suite("AVCDecoderConfigurationRecord")
struct AVCDecoderConfigurationRecordTests {

    @Test func `should write the avcC record from a stream's SPS and PPS`() {
        let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAA])
        let pps = Data([0x68, 0xEE])

        #expect(AVCDecoderConfigurationRecord.bytes(sps: sps, pps: pps) == Data(
            [0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x05] + [0x67, 0x64, 0x00, 0x1F, 0xAA]
                + [0x01, 0x00, 0x02] + [0x68, 0xEE]))
    }

    @Test func `should write no record when the SPS is too short to name its profile`() {
        #expect(AVCDecoderConfigurationRecord.bytes(sps: Data([0x67, 0x64]), pps: Data([0x68])) == nil)
    }
}
