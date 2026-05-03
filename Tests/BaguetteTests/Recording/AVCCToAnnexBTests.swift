import Testing
import Foundation
@testable import Baguette

/// AVCC ↔ Annex B is a pure bytes → bytes transform — pure parser tests.
/// AVCC frames are 4-byte big-endian length followed by raw NAL bytes,
/// possibly concatenated. Annex B prefixes each NAL with the start code
/// `0x00 0x00 0x00 0x01`. ffmpeg `-f h264 -i pipe:` reads Annex B.
@Suite("AVCCToAnnexB")
struct AVCCToAnnexBTests {

    @Test func `single NALU prepends 4-byte start code`() {
        let nal: [UInt8] = [0x65, 0x88, 0x84, 0x00]
        let avcc = Data([0, 0, 0, 4] + nal)

        let annexB = AVCCToAnnexB.naluPayloads(fromAvcc: avcc)
        #expect(Array(annexB) == [0, 0, 0, 1] + nal)
    }

    @Test func `multiple NALUs are emitted back-to-back, each with a start code`() {
        let nalA: [UInt8] = [0x67, 0x42]                       // SPS-ish
        let nalB: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]           // PPS-ish
        var avcc = Data([0, 0, 0, UInt8(nalA.count)] + nalA)
        avcc.append(Data([0, 0, 0, UInt8(nalB.count)] + nalB))

        let annexB = AVCCToAnnexB.naluPayloads(fromAvcc: avcc)
        #expect(Array(annexB) ==
                [0, 0, 0, 1] + nalA +
                [0, 0, 0, 1] + nalB)
    }

    @Test func `empty AVCC yields empty output`() {
        #expect(AVCCToAnnexB.naluPayloads(fromAvcc: Data()) == Data())
    }

    @Test func `truncated length header yields empty output (no crash)`() {
        // 3-byte buffer can't even hold a length prefix.
        let bad = Data([0, 0, 0])
        #expect(AVCCToAnnexB.naluPayloads(fromAvcc: bad) == Data())
    }

    @Test func `length larger than remaining bytes is dropped`() {
        // length=99 but only 2 NAL bytes follow — drop the truncated NAL,
        // don't crash, don't emit a partial Annex B unit.
        let bad = Data([0, 0, 0, 99, 0xAB, 0xCD])
        #expect(AVCCToAnnexB.naluPayloads(fromAvcc: bad) == Data())
    }

    /// avcC parameter-set blob layout (ISO/IEC 14496-15 §5.2.4.1):
    ///   [0]    configurationVersion  (0x01)
    ///   [1..3] AVCProfileIndication / profile_compat / AVCLevelIndication (from SPS[1..3])
    ///   [4]    0xFC | (lengthSizeMinusOne)        — we always emit 0xFF (4-byte length)
    ///   [5]    0xE0 | numOfSequenceParameterSets — we always emit 0xE1 (one SPS)
    ///   [6..7] sequenceParameterSetLength (BE)
    ///   [...]  SPS bytes
    ///   [+1]   numOfPictureParameterSets         — we always emit 0x01 (one PPS)
    ///   [+2]   pictureParameterSetLength (BE)
    ///   [...]  PPS bytes
    @Test func `parameter sets blob expands to SPS + PPS Annex B units`() {
        let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0x00, 0x00]
        let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]

        var blob = Data()
        blob.append(0x01)                         // configurationVersion
        blob.append(sps[1]); blob.append(sps[2]); blob.append(sps[3])
        blob.append(0xFF)                         // lengthSizeMinusOne = 3
        blob.append(0xE1)                         // 1 SPS
        blob.append(0); blob.append(UInt8(sps.count))
        blob.append(contentsOf: sps)
        blob.append(0x01)                         // 1 PPS
        blob.append(0); blob.append(UInt8(pps.count))
        blob.append(contentsOf: pps)

        let annexB = AVCCToAnnexB.parameterSetsAnnexB(fromAvcCBlob: blob)
        #expect(annexB != nil)
        #expect(Array(annexB!) ==
                [0, 0, 0, 1] + sps +
                [0, 0, 0, 1] + pps)
    }

    @Test func `malformed parameter sets blob returns nil`() {
        // Random 3 bytes — not an avcC blob.
        let bad = Data([0xFF, 0xFE, 0xFD])
        #expect(AVCCToAnnexB.parameterSetsAnnexB(fromAvcCBlob: bad) == nil)
    }
}
