import Foundation
import Testing
@testable import Baguette

@Suite("AVCCParameterSets")
struct AVCCParameterSetsTests {
    /// A minimal synthetic avcC blob: one 3-byte SPS, one 2-byte PPS,
    /// 4-byte NALU length prefixes.
    private let avcC = Data([
        0x01,             // configurationVersion
        0x64, 0x00, 0x28, // profile / compat / level
        0xFF,             // lengthSizeMinusOne = 3 → 4-byte prefixes
        0xE1,             // numOfSequenceParameterSets = 1
        0x00, 0x03, 0x67, 0x42, 0x00,  // SPS length + bytes
        0x01,             // numOfPictureParameterSets = 1
        0x00, 0x02, 0x68, 0xCE,        // PPS length + bytes
    ])

    @Test func `parses sps and pps out of an avcC blob`() {
        let sets = AVCCParameterSets.parse(avcC: avcC)
        #expect(sets?.sps == [Data([0x67, 0x42, 0x00])])
        #expect(sets?.pps == [Data([0x68, 0xCE])])
    }

    @Test func `reads the nalu length prefix size from the blob`() {
        #expect(AVCCParameterSets.parse(avcC: avcC)?.naluHeaderLength == 4)
    }

    @Test func `rejects truncated blobs`() {
        for cut in [0, 4, 6, 8, 11] {
            #expect(AVCCParameterSets.parse(avcC: avcC.prefix(cut)) == nil)
        }
    }

    @Test func `rejects a parameter-set length that overruns the blob`() {
        var lying = avcC
        lying[6] = 0xFF
        #expect(AVCCParameterSets.parse(avcC: lying) == nil)
    }
}
