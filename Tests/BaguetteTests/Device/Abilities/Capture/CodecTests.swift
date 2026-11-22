import CoreMedia
import Foundation
import Testing
@testable import BaguetteDevice

/// A codec as baguette encodes it: which encoder to open, its profile, the
/// decoder configuration record its encoder makes, and the parameter sets in it.
@Suite("H264Codec")
struct H264CodecTests {
    /// An avcC record: version 1, High profile, 4-byte lengths, one SPS, one PPS.
    static let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC])
    static let pps = Data([0x68, 0xEE, 0x3C, 0x80])
    static let avcC = Data([0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x05]) + sps + Data([0x01, 0x00, 0x04]) + pps

    @Test func `should open an H.264 encoder, in High profile`() {
        #expect(H264Codec().codecType == kCMVideoCodecType_H264)
        #expect(H264Codec().profile == .highProfileAutoLevel)
    }

    @Test func `should find its decoder configuration in the avcC record`() {
        #expect(H264Codec().recordAtom == "avcC")
    }

    @Test func `should read its parameter sets, SPS then PPS, out of its record`() {
        #expect(H264Codec().parameterSets(record: Self.avcC) == [Self.sps, Self.pps])
        #expect(H264Codec().parameterSets(record: Data([0x02])) == nil)
    }
}
