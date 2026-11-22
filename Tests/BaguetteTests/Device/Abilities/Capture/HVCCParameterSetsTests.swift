import Foundation
import Testing
@testable import BaguetteDevice

/// The VPS, SPS and PPS inside an hvcC record (ISO/IEC 14496-15 §8.3.3) —
/// what an H.265 sender puts ahead of a keyframe.
@Suite("HVCCParameterSets")
struct HVCCParameterSetsTests {
    static let vps = Data([0x40, 0x01, 0x0C])
    static let sps = Data([0x42, 0x01, 0x01, 0x01])
    static let pps = Data([0x44, 0x01, 0xC1])
    static let sei = Data([0x4E, 0x01, 0x05])

    /// The 22-byte header: version 1, Main profile, level 120, 4-byte lengths.
    static let header = Data([0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x78, 0xF0, 0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00, 0x0F])

    static func array(_ type: UInt8, _ units: [Data]) -> Data {
        var bytes = Data([0x80 | type, 0x00, UInt8(units.count)])
        for unit in units { bytes += Data([0x00, UInt8(unit.count)]) + unit }
        return bytes
    }

    static func record(_ arrays: [Data]) -> Data {
        header + Data([UInt8(arrays.count)]) + arrays.reduce(Data(), +)
    }

    static let hvcC = record([array(32, [vps]), array(33, [sps]), array(34, [pps])])

    @Test func `should read the vps, sps and pps out of an hvcC record`() {
        let sets = HVCCParameterSets.parse(hvcC: Self.hvcC)
        #expect(sets?.vps == [Self.vps])
        #expect(sets?.sps == [Self.sps])
        #expect(sets?.pps == [Self.pps])
    }

    @Test func `should read the nalu length prefix size from an hvcC record`() {
        #expect(HVCCParameterSets.parse(hvcC: Self.hvcC)?.naluHeaderLength == 4)
    }

    @Test func `should leave out other nal units when an hvcC record carries them`() {
        let withSEI = Self.record([Self.array(32, [Self.vps]), Self.array(33, [Self.sps]),
                                   Self.array(34, [Self.pps]), Self.array(39, [Self.sei])])
        #expect(HVCCParameterSets.parse(hvcC: withSEI)?.inSendingOrder == [Self.vps, Self.sps, Self.pps])
    }

    @Test func `should send the vps, then the sps, then the pps whatever order the record lists them in`() {
        let shuffled = Self.record([Self.array(34, [Self.pps]), Self.array(32, [Self.vps]), Self.array(33, [Self.sps])])
        #expect(HVCCParameterSets.parse(hvcC: shuffled)?.inSendingOrder == [Self.vps, Self.sps, Self.pps])
    }

    @Test func `should reject an hvcC record that isn't version 1`() {
        var other = Self.hvcC
        other[0] = 0x02
        #expect(HVCCParameterSets.parse(hvcC: other) == nil)
    }

    @Test func `should reject a truncated hvcC record`() {
        for cut in [0, 10, 22, 23, 25, 27, Self.hvcC.count - 1] {
            #expect(HVCCParameterSets.parse(hvcC: Self.hvcC.prefix(cut)) == nil)
        }
    }

    @Test func `should reject an hvcC record when a parameter set is missing`() {
        let noPPS = Self.record([Self.array(32, [Self.vps]), Self.array(33, [Self.sps])])
        #expect(HVCCParameterSets.parse(hvcC: noPPS) == nil)
    }
}
