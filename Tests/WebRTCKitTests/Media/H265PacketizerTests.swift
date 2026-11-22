import Foundation
import Testing
@testable import WebRTCKit

/// A picture as the encoder hands it over: each NAL unit behind a 4-byte length.
private func lengthPrefixed(_ nalUnits: [Data]) -> Data {
    nalUnits.reduce(into: Data()) { out, nal in
        out.append(contentsOf: withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init))
        out.append(nal)
    }
}

/// An H.265 IDR slice (IDR_W_RADL, type 19; layer 0, temporal id 1) of `size`
/// bytes, its 2-byte header first.
private func idrSlice(_ size: Int) -> Data {
    Data([0x26, 0x01] + (2..<size).map { UInt8(truncatingIfNeeded: $0) })
}

/// Cutting one H.265 picture into RTP payloads (RFC 7798): a NAL unit that
/// fits goes as it is, a larger one as fragmentation units, the parameter sets
/// ahead of a keyframe as one aggregation packet.
@Suite("H265Packetizer")
struct H265PacketizerTests {
    let packetizer = H265Packetizer()

    @Test func `should send an H.265 NAL unit that fits in one packet as it is`() {
        let nal = idrSlice(300)
        #expect(packetizer.payloads(picture: lengthPrefixed([nal])) == [nal])
    }

    @Test func `should send each NAL unit of a picture in its own packet, in order`() {
        let first = Data([0x02, 0x01, 1, 2]), second = Data([0x02, 0x01, 3, 4])   // TRAIL_R slices
        #expect(packetizer.payloads(picture: lengthPrefixed([first, second])) == [first, second])
    }

    @Test func `should fragment a NAL unit too big for one packet into fragmentation units with start and end bits`() {
        let nal = idrSlice(3000)

        let payloads = packetizer.payloads(picture: lengthPrefixed([nal]))

        #expect(payloads.count == 3)
        #expect(payloads.allSatisfy { $0.count <= H265Packetizer.maxPayload })
        // Payload header: the NAL's header with its type replaced by 49 — F 0, type 49, layer 0, TID 1.
        #expect(payloads.map { [$0[0], $0[1]] } == [[0x62, 0x01], [0x62, 0x01], [0x62, 0x01]])
        // FU header: start / end bits and the NAL's own type, 19.
        #expect(payloads.map { $0[2] } == [0x93, 0x13, 0x53])
        // The NAL's 2-byte header isn't repeated: the pieces put back behind it rebuild it.
        let rebuilt = Data([nal[0], nal[1]]) + payloads.reduce(into: Data()) { $0.append($1.dropFirst(3)) }
        #expect(rebuilt == nal)
    }

    @Test func `should bundle VPS, SPS and PPS into one aggregation packet ahead of a keyframe`() {
        let vps = Data([0x40, 0x01, 0x0C]), sps = Data([0x42, 0x01, 0x01, 0x01]), pps = Data([0x44, 0x01, 0xC1])
        let slice = idrSlice(10)

        let payloads = packetizer.payloads(picture: lengthPrefixed([slice]), parameterSets: [vps, sps, pps])

        // Payload header: F 0, type 48, the lowest layer (0) and temporal id (1); then each unit behind 2 bytes of length.
        var aggregate = Data([0x60, 0x01])
        aggregate.append(contentsOf: [0x00, 0x03]); aggregate.append(vps)
        aggregate.append(contentsOf: [0x00, 0x04]); aggregate.append(sps)
        aggregate.append(contentsOf: [0x00, 0x03]); aggregate.append(pps)
        #expect(payloads == [aggregate, slice])
    }

    @Test func `should send the parameter sets each in its own packet when together they don't fit one`() {
        let vps = Data([0x40, 0x01] + [UInt8](repeating: 1, count: 498))
        let sps = Data([0x42, 0x01] + [UInt8](repeating: 2, count: 498))
        let pps = Data([0x44, 0x01] + [UInt8](repeating: 3, count: 498))

        let payloads = packetizer.payloads(picture: lengthPrefixed([idrSlice(10)]), parameterSets: [vps, sps, pps])

        #expect(payloads == [vps, sps, pps, idrSlice(10)])
        #expect(payloads.allSatisfy { $0.count <= H265Packetizer.maxPayload })
    }

    @Test func `should give an aggregation packet the lowest temporal id of what it carries`() {
        let tid2 = Data([0x40, 0x02, 0xAA]), tid1 = Data([0x42, 0x01, 0xBB])
        let payloads = packetizer.payloads(picture: Data(), parameterSets: [tid2, tid1])
        #expect(payloads.first.map { [$0[0], $0[1]] } == [0x60, 0x01])
    }
}

/// The sender holds a packetizer by its role, so a codec is a new type, never
/// an edit to the sender.
@Suite("RTPPacketizer")
struct RTPPacketizerTests {
    @Test func `should let either codec's packetizer cut a picture through the same role`() {
        let h264: any RTPPacketizer = H264Packetizer()
        let h265: any RTPPacketizer = H265Packetizer()
        let picture = lengthPrefixed([Data([0x41, 1, 2])])
        #expect(h264.payloads(picture: picture, parameterSets: []) == [Data([0x41, 1, 2])])
        #expect(h265.payloads(picture: picture, parameterSets: []) == [Data([0x41, 1, 2])])
    }
}
