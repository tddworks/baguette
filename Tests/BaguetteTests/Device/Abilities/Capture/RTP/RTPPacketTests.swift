import Foundation
import Testing
@testable import BaguetteDevice

/// RTP header: V=2, P=0, X, CC; M, PT; sequence; timestamp; SSRC.
private func rtp(
    marker: Bool = false, payloadType: UInt8 = 123, sequence: UInt16 = 1, timestamp: UInt32 = 9000,
    ssrc: UInt32 = 0xE95D_3647, csrcs: [UInt32] = [], extensionWords: [UInt32]? = nil, payload: [UInt8]
) -> Data {
    var bytes: [UInt8] = [0x80 | (extensionWords == nil ? 0 : 0x10) | UInt8(csrcs.count),
                          (marker ? 0x80 : 0) | payloadType]
    bytes += withUnsafeBytes(of: sequence.bigEndian, Array.init)
    bytes += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
    bytes += withUnsafeBytes(of: ssrc.bigEndian, Array.init)
    for csrc in csrcs { bytes += withUnsafeBytes(of: csrc.bigEndian, Array.init) }
    if let words = extensionWords {
        bytes += [0x90, 0x11] + withUnsafeBytes(of: UInt16(words.count).bigEndian, Array.init)
        for word in words { bytes += withUnsafeBytes(of: word.bigEndian, Array.init) }
    }
    return Data(bytes + payload)
}

/// A packet the test means to be valid.
private func parsed(_ data: Data) -> RTPPacket { RTPPacket(data)! }

@Suite("RTPPacket")
struct RTPPacketTests {
    @Test func `should read an RTP packet's sequence, timestamp, marker, source and payload`() throws {
        let packet = parsed(rtp(marker: true, sequence: 0x6D4E, timestamp: 1234, payload: [0x65, 1, 2]))

        #expect(packet.sequence == 0x6D4E)
        #expect(packet.timestamp == 1234)
        #expect(packet.marker)
        #expect(packet.payloadType == 123)
        #expect(packet.ssrc == 0xE95D_3647)
        #expect(packet.payload == Data([0x65, 1, 2]))
    }

    @Test func `should skip a header extension and contributing sources to reach the payload`() throws {
        let packet = parsed(rtp(csrcs: [7, 8], extensionWords: [0xAAAA_AAAA, 0xBBBB_BBBB], payload: [0x41, 9]))

        #expect(packet.payload == Data([0x41, 9]))
    }

    @Test func `should read no packet from bytes that are too short or not RTP version 2`() {
        #expect(RTPPacket(Data([0x80, 100, 0])) == nil)
        #expect(RTPPacket(Data([0x40] + [UInt8](repeating: 0, count: 15))) == nil)
        #expect(RTPPacket(rtp(extensionWords: [1], payload: []).prefix(14)) == nil)
    }

    @Test func `should write the header a phone's parser reads back`() {
        let packet = RTPPacket(
            marker: true, payloadType: 102, sequence: 0xFFFE, timestamp: 0x0102_0304,
            ssrc: 0xCAFE_F00D, payload: Data([0x65, 0x88, 0x84]))

        #expect(packet.data == rtp(marker: true, payloadType: 102, sequence: 0xFFFE, timestamp: 0x0102_0304,
                                   ssrc: 0xCAFE_F00D, payload: [0x65, 0x88, 0x84]))
        #expect(RTPPacket(packet.data) == packet)
    }

    @Test func `should carry a one-byte header extension, padded to a whole word`() {
        let packet = RTPPacket(
            marker: false, payloadType: 112, sequence: 7, timestamp: 9000, ssrc: 1,
            payload: Data([0x65]), extensions: [RTPHeaderExtension(id: 3, data: [0x12, 0x34])])

        // X bit set; 0xBEDE, one word; element (id 3, length 2 → 0x31), the data, one byte of padding.
        #expect(packet.data == Data([0x90, 112, 0, 7, 0, 0, 0x23, 0x28, 0, 0, 0, 1,
                                     0xBE, 0xDE, 0, 1, 0x31, 0x12, 0x34, 0, 0x65]))
        #expect(RTPPacket(packet.data) == packet)
    }

    @Test func `should read a browser's one-byte extensions and skip their padding`() throws {
        let wire = Data([0x90, 112, 0, 7, 0, 0, 0x23, 0x28, 0, 0, 0, 1,
                         0xBE, 0xDE, 0, 2, 0x10, 0xAA, 0, 0, 0x22, 1, 2, 3, 0x65])
        let packet = try #require(RTPPacket(wire))

        #expect(packet.extensions == [RTPHeaderExtension(id: 1, data: [0xAA]), RTPHeaderExtension(id: 2, data: [1, 2, 3])])
        #expect(packet.payload == Data([0x65]))
    }

    @Test func `should tell an RTCP report apart from media`() {
        // RTCP sender report: PT 200 lands in the RTP marker+type byte as 0xC8.
        let report = Data([0x80, 0xC8, 0x00, 0x06] + [UInt8](repeating: 0, count: 24))
        #expect(RTPPacket.isRTCP(report))
        #expect(!RTPPacket.isRTCP(rtp(payload: [0x65])))
    }
}
