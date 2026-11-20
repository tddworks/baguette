import Foundation
import Testing
@testable import WebRTCKit

private let transportWideURI = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
private let absSendTimeURI = "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"

private func offer(_ extensions: [String]) -> SessionDescription {
    try! SessionDescription(offer: ([
        "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112", "a=mid:0",
        "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass", "a=fingerprint:sha-256 6B:8B",
    ] + extensions + [
        "a=rtpmap:112 H264/90000",
        "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
    ]).joined(separator: "\r\n"))
}
private let both = offer([
    "a=extmap:2 " + absSendTimeURI, "a=extmap:3 " + transportWideURI, "a=rtcp-fb:112 goog-remb", "a=rtcp-fb:112 transport-cc",
])
private let rembOnly = offer(["a=extmap:2 " + absSendTimeURI, "a=rtcp-fb:112 goog-remb"])
private let neither = offer([])

@Suite("TransportWideControl")
struct TransportWideControlTests {
    @Test func `should ask the answer for transport-cc feedback and its extension`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)

        #expect(control.answerLines() == ["a=extmap:3 " + transportWideURI, "a=rtcp-fb:112 transport-cc"])
    }

    @Test func `should number each packet it stamps, one after another`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)

        let first = control.extensions(at: 0)
        control.sent(size: 1_200, at: 0)
        let second = control.extensions(at: 100)

        #expect(first == [RTPHeaderExtension(id: 3, data: [0, 0])])
        #expect(second == [RTPHeaderExtension(id: 3, data: [0, 1])])
    }

    @Test func `should start at its ceiling and follow what the browser's reports show`() {
        let control = TransportWideControl(extensionID: 3, payloadType: 112, ceiling: 8_000_000)
        #expect(control.target == 8_000_000)
        for _ in 0..<30 {
            _ = control.extensions(at: 0)
            control.sent(size: 1_200, at: 0)
        }

        control.heard(.transportFeedback(TransportFeedback(
            feedbackCount: 0, arrivals: (0..<30).map { .init(sequence: UInt16($0), microseconds: nil) })), at: 600_000)

        // All still missing half a second after they left: lost, and the loss-based rate halves.
        #expect(control.target == 4_000_000)
    }
}

@Suite("ReceiverEstimateControl")
struct ReceiverEstimateControlTests {
    @Test func `should ask the answer for REMB feedback and the abs-send-time extension`() {
        let control = ReceiverEstimateControl(extensionID: 2, payloadType: 112, ceiling: 8_000_000)

        #expect(control.answerLines() == ["a=extmap:2 " + absSendTimeURI, "a=rtcp-fb:112 goog-remb"])
    }

    @Test func `should stamp each packet with its send time in 6.18 fixed-point seconds`() {
        let control = ReceiverEstimateControl(extensionID: 2, payloadType: 112, ceiling: 8_000_000)

        #expect(control.extensions(at: 1_500_000) == [RTPHeaderExtension(id: 2, data: [0x06, 0x00, 0x00])])
        // It wraps every 64 s.
        #expect(control.extensions(at: 64_250_000) == [RTPHeaderExtension(id: 2, data: [0x01, 0x00, 0x00])])
    }

    @Test func `should take the browser's estimate as its target, between its floor and ceiling`() {
        let control = ReceiverEstimateControl(extensionID: 2, payloadType: 112, ceiling: 8_000_000)
        #expect(control.target == 8_000_000)

        control.heard(.bandwidthEstimate(bitsPerSecond: 2_500_000), at: 0)
        #expect(control.target == 2_500_000)
        control.heard(.bandwidthEstimate(bitsPerSecond: 20_000_000), at: 0)
        #expect(control.target == 8_000_000)
        control.heard(.bandwidthEstimate(bitsPerSecond: 100_000), at: 0)
        #expect(control.target == 300_000)
    }
}

@Suite("FixedBitrate")
struct FixedBitrateTests {
    @Test func `should ask for nothing, stamp nothing and want no bitrate of its own`() {
        let control = FixedBitrate()

        control.heard(.bandwidthEstimate(bitsPerSecond: 1_000_000), at: 0)
        control.sent(size: 1_200, at: 0)

        #expect(control.answerLines().isEmpty)
        #expect(control.extensions(at: 0).isEmpty)
        #expect(control.target == nil)
    }
}

@Suite("CongestionChoice")
struct CongestionChoiceTests {
    @Test func `should name the methods the way the switch spells them`() {
        #expect(CongestionChoice(rawValue: "transport-cc") == .transportWide)
        #expect(CongestionChoice(rawValue: "remb") == .receiverEstimate)
        #expect(CongestionChoice(rawValue: "off") == .off)
        #expect(CongestionChoice(rawValue: "gcc") == nil)
    }

    @Test func `should take transport-cc when offered, else REMB, else none, when nothing is asked`() {
        #expect(CongestionChoice.control(asked: nil, offer: both, ceiling: 8_000_000) is TransportWideControl)
        #expect(CongestionChoice.control(asked: nil, offer: rembOnly, ceiling: 8_000_000) is ReceiverEstimateControl)
        #expect(CongestionChoice.control(asked: nil, offer: neither, ceiling: 8_000_000) is FixedBitrate)
    }

    @Test func `should take the method asked for when the offer can carry it, else none`() {
        #expect(CongestionChoice.control(asked: .receiverEstimate, offer: both, ceiling: 8_000_000) is ReceiverEstimateControl)
        #expect(CongestionChoice.control(asked: .transportWide, offer: rembOnly, ceiling: 8_000_000) is FixedBitrate)
        #expect(CongestionChoice.control(asked: .off, offer: both, ceiling: 8_000_000) is FixedBitrate)
    }
}
