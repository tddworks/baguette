import Foundation
import Testing
@testable import Baguette

/// RTP header: V=2, P=0, X, CC; M, PT; sequence; timestamp; SSRC.
private func rtp(
    marker: Bool = false, payloadType: UInt8 = 100, sequence: UInt16 = 1, timestamp: UInt32 = 9000,
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
        #expect(packet.payloadType == 100)
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

    @Test func `should tell an RTCP report apart from media`() {
        // RTCP sender report: PT 200 lands in the RTP marker+type byte as 0xC8.
        let report = Data([0x80, 0xC8, 0x00, 0x06] + [UInt8](repeating: 0, count: 24))
        #expect(RTPPacket.isRTCP(report))
        #expect(!RTPPacket.isRTCP(rtp(payload: [0x65])))
    }
}

@Suite("H264Depacketizer")
struct H264DepacketizerTests {
    private let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC]
    private let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]

    @Test func `should hand back an access unit once its last packet arrives`() throws {
        var depacketizer = H264Depacketizer()

        #expect(depacketizer.push(parsed(rtp(sequence: 1, payload: sps))) == nil)
        let pushed = depacketizer.push(parsed(rtp(marker: true, sequence: 2, payload: [0x65, 0xAA])))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [Data(sps), Data([0x65, 0xAA])])
        #expect(unit.timestamp == 9000)
    }

    @Test func `should split an aggregation packet into its NAL units`() throws {
        var depacketizer = H264Depacketizer()
        // STAP-A: header 24, then [size16, NAL]...
        let stap: [UInt8] = [0x78] + [0, UInt8(sps.count)] + sps + [0, UInt8(pps.count)] + pps

        let pushed = depacketizer.push(parsed(rtp(marker: true, payload: stap)))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [Data(sps), Data(pps)])
    }

    @Test func `should rebuild a fragmented NAL unit from its fragments`() throws {
        var depacketizer = H264Depacketizer()
        // FU-A: indicator (F|NRI|28), header (S|E|R|type).
        let first: [UInt8] = [0x7C, 0x85, 1, 2]
        let middle: [UInt8] = [0x7C, 0x05, 3]
        let last: [UInt8] = [0x7C, 0x45, 4]

        _ = depacketizer.push(parsed(rtp(sequence: 10, payload: first)))
        _ = depacketizer.push(parsed(rtp(sequence: 11, payload: middle)))
        let pushed = depacketizer.push(parsed(rtp(marker: true, sequence: 12, payload: last)))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [Data([0x65, 1, 2, 3, 4])])
    }

    @Test func `should drop a frame that lost a fragment rather than decode a broken one`() throws {
        var depacketizer = H264Depacketizer()

        _ = depacketizer.push(parsed(rtp(sequence: 10, payload: [0x7C, 0x85, 1])))
        // sequence 11 never arrives
        let lost = depacketizer.push(parsed(rtp(marker: true, sequence: 12, payload: [0x7C, 0x45, 4])))
        let next = depacketizer.push(parsed(rtp(marker: true, sequence: 13, timestamp: 12000, payload: [0x41, 7])))

        #expect(lost == nil)
        #expect(next?.nalUnits == [Data([0x41, 7])])
    }

    @Test func `should start a new access unit when the timestamp moves on without a marker`() throws {
        var depacketizer = H264Depacketizer()

        _ = depacketizer.push(parsed(rtp(sequence: 1, timestamp: 100, payload: [0x41, 1])))
        let previous = depacketizer.push(parsed(rtp(sequence: 2, timestamp: 200, payload: [0x41, 2])))

        #expect(previous?.nalUnits == [Data([0x41, 1])])
        #expect(previous?.timestamp == 100)
    }
}

@Suite("AccessUnit")
struct AccessUnitTests {
    private let sps = Data([0x67, 0x64, 0x00, 0x33, 0xAC])
    private let pps = Data([0x68, 0xEE, 0x3C, 0x80])

    @Test func `should know a frame that starts an IDR is a keyframe`() {
        #expect(AccessUnit(nalUnits: [sps, pps, Data([0x65, 1])], timestamp: 0).isKeyframe)
        #expect(!AccessUnit(nalUnits: [Data([0x41, 1])], timestamp: 0).isKeyframe)
    }

    @Test func `should describe its parameter sets as the avcC a decoder is configured with`() throws {
        let unit = AccessUnit(nalUnits: [sps, pps, Data([0x65, 1])], timestamp: 0)

        let description = try #require(unit.decoderDescription)

        #expect(description.prefix(5) == Data([1, 0x64, 0x00, 0x33, 0xFF]))
        let parsed = try #require(AVCCParameterSets.parse(avcC: description))
        #expect(parsed.sps == [sps])
        #expect(parsed.pps == [pps])
    }

    @Test func `should have no decoder description without both parameter sets`() {
        #expect(AccessUnit(nalUnits: [Data([0x65, 1])], timestamp: 0).decoderDescription == nil)
    }

    @Test func `should frame its picture NAL units with four-byte lengths and leave the parameter sets out`() {
        let unit = AccessUnit(nalUnits: [sps, pps, Data([0x65, 1, 2])], timestamp: 0)

        #expect(unit.lengthPrefixedFrame == Data([0, 0, 0, 3, 0x65, 1, 2]))
    }
}

@Suite("RTCPReceiverReport")
struct RTCPReceiverReportTests {
    @Test func `should report on the phone's stream from our source, as RTCP receiver report bytes`() {
        let report = RTCPReceiverReport(reporter: 0xD6AF_5E2E, source: 0xE95D_3647, highestSequence: 0x0001_6D4E)

        #expect(report.bytes == Data([
            0x81, 0xC9, 0x00, 0x07,             // V=2, one report block, RR, length 7 words
            0xD6, 0xAF, 0x5E, 0x2E,             // our SSRC
            0xE9, 0x5D, 0x36, 0x47,             // the phone's SSRC
            0x00, 0x00, 0x00, 0x00,             // nothing lost
            0x00, 0x01, 0x6D, 0x4E,             // extended highest sequence
            0x00, 0x00, 0x00, 0x00,             // jitter
            0x00, 0x00, 0x00, 0x00,             // last SR
            0x00, 0x00, 0x00, 0x00,             // delay since last SR
        ]))
    }

    @Test func `should ask the phone for a fresh keyframe with a picture loss indication`() {
        #expect(RTCPReceiverReport.pictureLossIndication(reporter: 1, source: 2) == Data([
            0x81, 0xCE, 0x00, 0x02, 0, 0, 0, 1, 0, 0, 0, 2,
        ]))
    }
}

@Suite("TunnelAddress")
struct TunnelAddressTests {
    @Test func `should pick the Mac's address on the phone's tunnel prefix`() {
        let local = TunnelAddress.local(
            facing: "fdd3:48cf:f69f::1",
            among: ["fe80::1", "fd00:1:2::5", "fdd3:48cf:f69f::2", "fdd3:48cf:f69f::1"])

        #expect(local == "fdd3:48cf:f69f::2")
    }

    @Test func `should find no address when the Mac has none on the phone's prefix`() {
        #expect(TunnelAddress.local(facing: "fdd3:48cf:f69f::1", among: ["fe80::1"]) == nil)
    }
}
