import Foundation
import Testing
@testable import WebRTCKit

/// One RTCP packet: V=2, count/FMT, packet type, length in 32-bit words minus one.
private func rtcp(format: UInt8, type: UInt8, _ body: [UInt8]) -> [UInt8] {
    let words = body.count / 4
    return [0x80 | format, type, UInt8(words >> 8), UInt8(words & 0xFF)] + body
}

private let sender: [UInt8] = [0, 0, 0, 1], media: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
private let receiverReport = rtcp(format: 0, type: 201, sender)

@Suite("RTCPFeedback")
struct RTCPFeedbackTests {
    @Test func `should read a picture loss indication as a request for a keyframe`() {
        let pli = rtcp(format: 1, type: 206, sender + media)

        #expect(RTCPFeedback.parse(Data(pli)) == [.keyframeRequest])
    }

    @Test func `should read a full intra request as a request for a keyframe`() {
        let fir = rtcp(format: 4, type: 206, sender + [0, 0, 0, 0] + media + [3, 0, 0, 0])

        #expect(RTCPFeedback.parse(Data(fir)) == [.keyframeRequest])
    }

    @Test func `should read the packets a NACK reports lost`() {
        // Lost: 100, and through the bitmask 101 and 116.
        let nack = rtcp(format: 1, type: 205, sender + media + [0, 100, 0x80, 0x01])

        #expect(RTCPFeedback.parse(Data(nack)) == [.lost([100, 101, 116])])
    }

    @Test func `should read the bitrate the browser estimates it can receive`() {
        // REMB: "REMB", one SSRC, exponent 4 and mantissa 156250: 2.5 Mbps.
        let mantissa = 156_250
        let remb = rtcp(format: 15, type: 206, sender + [0, 0, 0, 0] + Array("REMB".utf8)
            + [1, UInt8(4 << 2 | mantissa >> 16), UInt8(mantissa >> 8 & 0xFF), UInt8(mantissa & 0xFF)] + media)

        #expect(RTCPFeedback.parse(Data(remb)) == [.bandwidthEstimate(bitsPerSecond: 2_500_000)])
    }

    @Test func `should read every feedback in a compound packet and skip the reports it doesn't act on`() {
        let compound = receiverReport + rtcp(format: 1, type: 206, sender + media)
            + rtcp(format: 1, type: 205, sender + media + [0, 7, 0, 0])

        #expect(RTCPFeedback.parse(Data(compound)) == [.keyframeRequest, .lost([7])])
    }

    @Test func `should read past feedback too short to act on, and application messages that aren't REMB`() {
        let noMediaSource = rtcp(format: 1, type: 206, sender)
        let emptyNACK = rtcp(format: 1, type: 205, sender + media)
        let notREMB = rtcp(format: 15, type: 206, sender + [0, 0, 0, 0] + Array("GOOG".utf8) + [1, 0, 0, 0])
        let shortREMB = rtcp(format: 15, type: 206, sender + [0, 0, 0, 0] + Array("REMB".utf8))

        #expect(RTCPFeedback.parse(Data(noMediaSource + emptyNACK + notREMB + shortREMB)).isEmpty)
    }

    @Test func `should stop at a packet whose length runs past the end`() {
        var cut = rtcp(format: 1, type: 206, sender + media)
        cut[3] = 9

        #expect(RTCPFeedback.parse(Data(receiverReport + rtcp(format: 1, type: 206, sender + media) + cut))
            == [.keyframeRequest])
        #expect(RTCPFeedback.parse(Data([0x80, 206])).isEmpty)
    }
}
