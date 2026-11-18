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

@Suite("VideoDepacketizer")
struct VideoDepacketizerTests {
    private let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC]
    private let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]

    @Test func `should hand back an access unit once its last packet arrives`() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)

        #expect(depacketizer.push(parsed(rtp(sequence: 1, payload: sps))) == nil)
        let pushed = depacketizer.push(parsed(rtp(marker: true, sequence: 2, payload: [0x65, 0xAA])))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [Data(sps), Data([0x65, 0xAA])])
        #expect(unit.timestamp == 9000)
    }

    @Test func `should split an aggregation packet into its NAL units`() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)
        // STAP-A: header 24, then [size16, NAL]...
        let stap: [UInt8] = [0x78] + [0, UInt8(sps.count)] + sps + [0, UInt8(pps.count)] + pps

        let pushed = depacketizer.push(parsed(rtp(marker: true, payload: stap)))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [Data(sps), Data(pps)])
    }

    @Test func `should rebuild a fragmented NAL unit from its fragments`() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)
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
        var depacketizer = VideoDepacketizer(codec: .h264)

        _ = depacketizer.push(parsed(rtp(sequence: 10, payload: [0x7C, 0x85, 1])))
        // sequence 11 never arrives
        let lost = depacketizer.push(parsed(rtp(marker: true, sequence: 12, payload: [0x7C, 0x45, 4])))
        let next = depacketizer.push(parsed(rtp(marker: true, sequence: 13, timestamp: 12000, payload: [0x41, 7])))

        #expect(lost == nil)
        #expect(next?.nalUnits == [Data([0x41, 7])])
    }

    @Test func `should start a new access unit when the timestamp moves on without a marker`() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)

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
        #expect(AccessUnit(codec: .h264, nalUnits: [sps, pps, Data([0x65, 1])], timestamp: 0).isKeyframe)
        #expect(!AccessUnit(codec: .h264, nalUnits: [Data([0x41, 1])], timestamp: 0).isKeyframe)
    }

    @Test func `should describe its parameter sets as the avcC a decoder is configured with`() throws {
        let unit = AccessUnit(codec: .h264, nalUnits: [sps, pps, Data([0x65, 1])], timestamp: 0)

        let description = try #require(unit.decoderDescription)

        #expect(description.prefix(5) == Data([1, 0x64, 0x00, 0x33, 0xFF]))
        let parsed = try #require(AVCCParameterSets.parse(avcC: description))
        #expect(parsed.sps == [sps])
        #expect(parsed.pps == [pps])
    }

    @Test func `should have no decoder description without both parameter sets`() {
        #expect(AccessUnit(codec: .h264, nalUnits: [Data([0x65, 1])], timestamp: 0).decoderDescription == nil)
    }

    @Test func `should frame its picture NAL units with four-byte lengths and leave the parameter sets out`() {
        let unit = AccessUnit(codec: .h264, nalUnits: [sps, pps, Data([0x65, 1, 2])], timestamp: 0)

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

    @Test func `should acknowledge each received picture to the phone`() {
        #expect(RTCPReceiverReport.pictureReceived(reporter: 0x00DB_16EB, timestamp: 5600) == Data([
            0x80, 0xCC, 0x00, 0x03,             // V=2, APP, length 3 words
            0x00, 0xDB, 0x16, 0xEB,             // our SSRC
            0x00, 0x00, 0x00, 0x05,             // the acknowledgement's name
            0x00, 0x00, 0x15, 0xE0,             // the picture's RTP timestamp
        ]))
    }

    @Test func `should tell the phone how many pictures and packets arrived, with a clock for round trips`() {
        let control = RTCPReceiverReport.receiverControl(
            reporter: 0x00DB_16EB, clock: 12438, pictures: 6, packets: 21)

        #expect(control == Data([
            0x80, 0xCC, 0x00, 0x07,             // V=2, APP, length 7 words
            0x00, 0xDB, 0x16, 0xEB,             // our SSRC
            0x52, 0x43, 0x54, 0x4C,             // "RCTL"
            0x85, 0x00, 0x00, 0x04,             // constant tag
            0x00, 0x06, 0x00, 0x00,             // pictures received
            0x00, 0x00, 0x00, 0x00,             // nothing amiss this interval
            0x30, 0x96, 0x00, 0x00,             // millisecond clock
            0x00, 0x15, 0x00, 0x00,             // highest sequence, past the first
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

@Suite("HEVC stream")
struct HEVCStreamTests {
    // Two-byte HEVC NAL headers: type << 1, then layer/temporal id 1.
    private let vps = Data([0x40, 0x01, 0x0C])
    private let sps = Data([0x42, 0x01, 0x01])
    private let pps = Data([0x44, 0x01, 0xC1])

    @Test func `should split an HEVC aggregation packet into its parameter sets`() throws {
        var depacketizer = VideoDepacketizer(codec: .hevc)
        // AP: payload header type 48, then [size16, NAL]...
        let ap = Data([0x60, 0x01] + [0, 3] + vps + [0, 3] + sps + [0, 3] + pps)

        let pushed = depacketizer.push(parsed(rtp(marker: true, payload: [UInt8](ap))))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [vps, sps, pps])
    }

    @Test func `should rebuild an HEVC NAL unit from its fragments`() throws {
        var depacketizer = VideoDepacketizer(codec: .hevc)
        // FU: payload header type 49, FU header S|E|type (19 = IDR_W_RADL).
        _ = depacketizer.push(parsed(rtp(sequence: 1, payload: [0x62, 0x01, 0x93, 0xAA])))
        let pushed = depacketizer.push(parsed(rtp(marker: true, sequence: 2, payload: [0x62, 0x01, 0x53, 0xBB])))
        let unit = try #require(pushed)

        #expect(unit.nalUnits == [Data([0x26, 0x01, 0xAA, 0xBB])])
        #expect(unit.isKeyframe)
    }

    @Test func `should name an HEVC frame's VPS, SPS and PPS as its parameter sets`() {
        let unit = AccessUnit(codec: .hevc, nalUnits: [vps, sps, pps, Data([0x26, 0x01, 9])], timestamp: 0)

        #expect(unit.parameterSets == [vps, sps, pps])
        #expect(unit.lengthPrefixedFrame == Data([0, 0, 0, 3, 0x26, 0x01, 9]))
    }

    @Test func `should know an HEVC trailing picture is not a keyframe`() {
        #expect(!AccessUnit(codec: .hevc, nalUnits: [Data([0x02, 0x01, 9])], timestamp: 0).isKeyframe)
    }

    @Test func `should name an H.264 frame's SPS and PPS as its parameter sets`() {
        let sps = Data([0x67, 0x64]), pps = Data([0x68, 0xEE])
        #expect(AccessUnit(codec: .h264, nalUnits: [sps, pps, Data([0x65, 1])], timestamp: 0).parameterSets == [sps, pps])
    }
}

@Suite("DecodeGate")
struct DecodeGateTests {
    private let keyframe = AccessUnit(codec: .hevc, nalUnits: [Data([0x26, 0x01, 1])], timestamp: 0)
    private let delta = AccessUnit(codec: .hevc, nalUnits: [Data([0x02, 0x01, 1])], timestamp: 0)

    @Test func `should wait for a keyframe before decoding anything`() {
        var gate = DecodeGate()

        let answer1 = gate.admits(delta, droppedSince: 0)
        #expect(!answer1)
        #expect(gate.needsKeyframe)
        let answer2 = gate.admits(keyframe, droppedSince: 0)
        #expect(answer2)
        #expect(!gate.needsKeyframe)
    }

    @Test func `should decode frames that follow a keyframe while nothing is lost`() {
        var gate = DecodeGate()
        _ = gate.admits(keyframe, droppedSince: 0)

        let answer3 = gate.admits(delta, droppedSince: 0)
        #expect(answer3)
    }

    @Test func `should stop decoding after a lost frame until the next keyframe`() {
        var gate = DecodeGate()
        _ = gate.admits(keyframe, droppedSince: 0)

        let answer4 = gate.admits(delta, droppedSince: 1)
        #expect(!answer4)
        #expect(gate.needsKeyframe)
        let answer5 = gate.admits(delta, droppedSince: 1)
        #expect(!answer5)
        let answer6 = gate.admits(keyframe, droppedSince: 1)
        #expect(answer6)
        let answer7 = gate.admits(delta, droppedSince: 1)
        #expect(answer7)
    }
}

@Suite("VideoDepacketizer losses")
struct VideoDepacketizerLossTests {
    @Test func `should count each frame it drops for a lost packet`() {
        var depacketizer = VideoDepacketizer(codec: .hevc)

        _ = depacketizer.push(parsed(rtp(sequence: 1, payload: [0x62, 0x01, 0x81, 1])))
        _ = depacketizer.push(parsed(rtp(marker: true, sequence: 3, payload: [0x62, 0x01, 0x41, 2])))

        #expect(depacketizer.droppedFrames == 1)
    }
}

@Suite("H.264 configuration packet")
struct H264ConfigurationPacketTests {
    private let sps: [UInt8] = [0x27, 0x64, 0x00, 0x33, 0xAC]
    private let pps: [UInt8] = [0x28, 0xEE, 0x3C, 0xB0]

    /// What the phone sends ahead of its first H.264 picture: a sample
    /// description whose avcC atom holds the SPS and PPS.
    private var configuration: [UInt8] {
        var record: [UInt8] = [1, 0x64, 0x00, 0x33, 0xFF, 0xE1, 0, UInt8(sps.count)]
        record += sps
        record += [1, 0, UInt8(pps.count)]
        record += pps
        var bytes: [UInt8] = [0x92, 0xE6, 0xC0, 0xA3, 0x61, 0x76, 0x63, 0x31, 0, 0, 0, 0]
        bytes += [0, 0, 0, UInt8(8 + record.count)]
        bytes += Array("avcC".utf8)
        bytes += record
        return bytes
    }

    @Test func `should hand a keyframe the parameter sets the phone sent ahead of it`() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)

        let config = try #require(RTPPacket(rtp(payloadType: 123, sequence: 1, payload: configuration)))
        let picture = try #require(RTPPacket(rtp(marker: true, payloadType: 123, sequence: 2, payload: [0x65, 0x88, 0x84])))

        let ahead = depacketizer.push(config)
        let pushed = depacketizer.push(picture)

        #expect(ahead == nil)
        let unit = try #require(pushed)

        #expect(unit.parameterSets == [Data(sps), Data(pps)])
        #expect(unit.isKeyframe)
    }

    @Test func `should not hand the parameter sets to a picture that isn't a keyframe`() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)

        let config = try #require(RTPPacket(rtp(payloadType: 123, sequence: 1, payload: configuration)))
        let picture = try #require(RTPPacket(rtp(marker: true, payloadType: 123, sequence: 2, payload: [0x41, 0x9A])))

        _ = depacketizer.push(config)
        let pushed = depacketizer.push(picture)
        let unit = try #require(pushed)

        #expect(unit.parameterSets.isEmpty)
    }
}

@Suite("MediaStreamOffer")
struct MediaStreamOfferTests {
    private let offer = MediaStreamOffer(
        receiver: 0x0102_0304, host: .init(model: "Mac16,11", build: "26A428"),
        callID: UUID(uuidString: "1B4753BF-F67F-48EC-B847-42B1FC17CD12")!, made: 0xEEA6_0000_0000_0000)

    @Test func `should offer the phone H.264 only, the codec whose stream stays whole under motion`() {
        // Protobuf: the receiver (field 5) lists one codec (field 3), payload type 123.
        let receiver: [UInt8] = [0x08, 0x84, 0x86, 0x88, 0x08, 0x10, 0x00, 0x1A, 0x3F, 0x08, 0x7B]
        #expect(offer.media.prefix(4) == Data([0x08, 0x01, 0x10, 0x01]))
        #expect(offer.media.range(of: Data(receiver)) != nil)
        #expect(offer.media.range(of: Data([0x1A, 0x2E, 0x08, 0x64])) == nil)
    }

    @Test func `should cap the phone's video at six megabits a second`() {
        #expect(offer.media.range(of: Data([0x4A, 0x0B, 0x08, 0x00, 0x10, 0x80, 0x9B, 0xEE, 0x02, 0x18, 0x80, 0x80, 0x08])) != nil)
    }

    @Test func `should wrap the offer as the property list the phone reads, naming the host`() throws {
        let plist = try #require(try PropertyListSerialization.propertyList(from: offer.bytes, format: nil) as? [String: Any])

        #expect(plist["avcMediaStreamNegotiatorMode"] as? Int == 5)
        #expect(plist["avcMediaStreamOptionCallID"] as? String == "1B4753BF-F67F-48EC-B847-42B1FC17CD12")
        var endpoint = Data([0x08, 0x00, 0x10, 0x01, 0x1A, 0x08])
        endpoint += Data("Mac16,11".utf8)
        endpoint += Data([0x22, 0x0B])
        endpoint += Data("2235.63.5.2".utf8)
        endpoint += Data([0x2A, 0x06])
        endpoint += Data("26A428".utf8)
        #expect(plist["avcMediaStreamOptionRemoteEndpointInfo"] as? Data == endpoint)
        let blob = try #require(plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)
        let inflated = try (blob.subdata(in: 2..<(blob.count - 4)) as NSData).decompressed(using: .zlib) as Data
        #expect(blob.prefix(1) == Data([0x78]))
        #expect(inflated == offer.media)
    }
}
