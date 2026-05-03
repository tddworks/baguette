import Testing
import Foundation
@testable import Baguette

/// AnnexBAssembler glues the AVCCStream's three encoder outputs
/// (description / keyframe / delta) into a single Annex B byte stream
/// suitable for piping to `ffmpeg -f h264 -i pipe:`. Pure transform —
/// no I/O, no subprocess — so the muxer's wire shape is fully driven
/// by tests.
@Suite("AnnexBAssembler")
struct AnnexBAssemblerTests {

    // Reusable shapes -------------------------------------------------
    private static let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0x00, 0x00]
    private static let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]

    private static func avcCBlob() -> Data {
        var blob = Data()
        blob.append(0x01)
        blob.append(sps[1]); blob.append(sps[2]); blob.append(sps[3])
        blob.append(0xFF)
        blob.append(0xE1)
        blob.append(0); blob.append(UInt8(sps.count))
        blob.append(contentsOf: sps)
        blob.append(0x01)
        blob.append(0); blob.append(UInt8(pps.count))
        blob.append(contentsOf: pps)
        return blob
    }

    private static func avccNAL(_ nal: [UInt8]) -> Data {
        var out = Data([0, 0, 0, UInt8(nal.count)])
        out.append(contentsOf: nal)
        return out
    }

    // -----------------------------------------------------------------

    @Test func `delta before any description emits empty (no half-stream output)`() {
        var asm = AnnexBAssembler()
        let nal: [UInt8] = [0x41, 0x01]
        let out = asm.delta(Self.avccNAL(nal))
        #expect(out.isEmpty)
    }

    @Test func `keyframe before any description emits empty`() {
        var asm = AnnexBAssembler()
        let nal: [UInt8] = [0x65, 0x01]
        let out = asm.keyframe(Self.avccNAL(nal))
        #expect(out.isEmpty)
    }

    @Test func `keyframe after description emits SPS+PPS+keyframe in order`() {
        var asm = AnnexBAssembler()
        asm.description(Self.avcCBlob())
        let kf: [UInt8] = [0x65, 0x88, 0x84, 0x00]
        let out = asm.keyframe(Self.avccNAL(kf))

        #expect(Array(out) ==
                [0, 0, 0, 1] + Self.sps +
                [0, 0, 0, 1] + Self.pps +
                [0, 0, 0, 1] + kf)
    }

    @Test func `subsequent keyframe re-emits SPS+PPS so seek points stay clean`() {
        var asm = AnnexBAssembler()
        asm.description(Self.avcCBlob())
        _ = asm.keyframe(Self.avccNAL([0x65, 0x01]))

        let kf2: [UInt8] = [0x65, 0x02]
        let out = asm.keyframe(Self.avccNAL(kf2))

        #expect(Array(out) ==
                [0, 0, 0, 1] + Self.sps +
                [0, 0, 0, 1] + Self.pps +
                [0, 0, 0, 1] + kf2)
    }

    @Test func `delta after first keyframe emits just the delta NALU`() {
        var asm = AnnexBAssembler()
        asm.description(Self.avcCBlob())
        _ = asm.keyframe(Self.avccNAL([0x65, 0x01]))

        let d: [UInt8] = [0x41, 0x9A]
        let out = asm.delta(Self.avccNAL(d))
        #expect(Array(out) == [0, 0, 0, 1] + d)
    }
}
