import Foundation
import Testing
@testable import BaguetteDevice

/// A recvonly video offer the way Chrome writes one, trimmed: VP8, two
/// Constrained Baseline H.264s (one in packetization mode 0), a High one, and
/// their retransmission formats.
private let chromeOffer = """
v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
a=msid-semantic: WMS
m=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103 106 107 112 113
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=ice-ufrag:Kq3e
a=ice-pwd:3Bk1bA0rxV2Ph9nU0rKrMEP8
a=ice-options:trickle
a=fingerprint:sha-256 6B:8B:5D:EA:59:04:20:23:29:C8:87:1C:CC:87:32:BE:DD:8C:66:A5:8E:50:55:EA:8C:D3:B6:5C:09:5E:D6:BC
a=setup:actpass
a=mid:0
a=recvonly
a=rtcp-mux
a=rtcp-rsize
a=rtpmap:96 VP8/90000
a=rtcp-fb:96 nack
a=rtpmap:97 rtx/90000
a=fmtp:97 apt=96
a=rtpmap:102 H264/90000
a=rtcp-fb:102 nack pli
a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f
a=rtpmap:103 rtx/90000
a=fmtp:103 apt=102
a=rtpmap:106 H264/90000
a=rtcp-fb:106 nack pli
a=fmtp:106 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=rtpmap:107 rtx/90000
a=fmtp:107 apt=106
a=rtpmap:112 H264/90000
a=rtcp-fb:112 nack pli
a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f
a=rtpmap:113 rtx/90000
a=fmtp:113 apt=112

""".replacingOccurrences(of: "\n", with: "\r\n")

private func offer(keepingFormats keep: (String) -> Bool) -> String {
    chromeOffer.components(separatedBy: "\r\n").filter(keep).joined(separator: "\r\n")
}

private let ours = ICECredentials(ufrag: "bgtt", password: "0123456789abcdefghijklmn")
private let fingerprint = "sha-256 AA:BB:CC"

@Suite("SessionDescription")
struct SessionDescriptionTests {
    @Test func `should read the browser's ICE credentials, DTLS fingerprint and media id from its offer`() throws {
        let description = try SessionDescription(offer: chromeOffer)

        #expect(description.browser == ICECredentials(ufrag: "Kq3e", password: "3Bk1bA0rxV2Ph9nU0rKrMEP8"))
        #expect(description.browserFingerprint
            == "sha-256 6B:8B:5D:EA:59:04:20:23:29:C8:87:1C:CC:87:32:BE:DD:8C:66:A5:8E:50:55:EA:8C:D3:B6:5C:09:5E:D6:BC")
        #expect(description.mid == "0")
    }

    @Test func `should pick the offer's High-profile H.264 in packetization mode 1`() throws {
        let description = try SessionDescription(offer: chromeOffer)

        #expect(description.payloadType == 112)
        #expect(description.profileLevelID == "64001f")
    }

    @Test func `should refuse an offer with no H.264 the encoder can send`() {
        // Baseline only, or High in packetization mode 0: neither carries what the encoder makes.
        let baselineOnly = offer { !$0.contains("profile-level-id=64001f") }
        #expect(throws: SessionDescription.Refusal.noH264) { try SessionDescription(offer: baselineOnly) }
        let vp8Only = offer { !$0.contains("H264") && !$0.hasPrefix("a=fmtp:1") }
        #expect(throws: SessionDescription.Refusal.noH264) { try SessionDescription(offer: vp8Only) }
    }

    @Test func `should refuse an offer with no video in it`() {
        let audio = "v=0\r\ns=-\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n"

        #expect(throws: SessionDescription.Refusal.noVideo) { try SessionDescription(offer: audio) }
    }

    @Test func `should refuse an offer that doesn't say how to reach and trust the browser`() {
        let noPassword = offer { !$0.hasPrefix("a=ice-pwd") }
        #expect(throws: SessionDescription.Refusal.noICECredentials) { try SessionDescription(offer: noPassword) }
        let noFingerprint = offer { !$0.hasPrefix("a=fingerprint") }
        #expect(throws: SessionDescription.Refusal.noFingerprint) { try SessionDescription(offer: noFingerprint) }
    }

    @Test func `should answer as an ICE-lite, DTLS-passive, send-only H.264 sender reachable at its candidates`() throws {
        let description = try SessionDescription(offer: chromeOffer)

        let answer = description.answer(
            ice: ours, fingerprint: fingerprint, ssrc: 0x1234_5678,
            candidates: [DatagramAddress(ip: [192, 168, 2, 221], port: 50000),
                         DatagramAddress(ip: [100, 76, 208, 108], port: 50000)])

        #expect(answer == [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=baguette",
            "t=0 0",
            "a=group:BUNDLE 0",
            "a=ice-lite",
            "m=video 9 UDP/TLS/RTP/SAVPF 112",
            "c=IN IP4 0.0.0.0",
            "a=mid:0",
            "a=sendonly",
            "a=rtcp-mux",
            "a=ice-ufrag:bgtt",
            "a=ice-pwd:0123456789abcdefghijklmn",
            "a=fingerprint:sha-256 AA:BB:CC",
            "a=setup:passive",
            "a=rtpmap:112 H264/90000",
            "a=rtcp-fb:112 nack",
            "a=rtcp-fb:112 nack pli",
            "a=rtcp-fb:112 ccm fir",
            "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
            "a=msid:baguette screen",
            "a=ssrc:305419896 cname:baguette",
            "a=candidate:1 1 udp 2130706431 192.168.2.221 50000 typ host",
            "a=candidate:2 1 udp 2130706430 100.76.208.108 50000 typ host",
            "a=end-of-candidates",
            "",
        ].joined(separator: "\r\n"))
    }
}

extension SessionDescriptionTests {
    @Test func `should write an IPv6 candidate in its colon form`() throws {
        let description = try SessionDescription(offer: chromeOffer)
        let v6 = DatagramAddress(ip: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02], port: 50000)

        let answer = description.answer(ice: ours, fingerprint: fingerprint, ssrc: 1, candidates: [v6])

        #expect(answer.contains("a=candidate:1 1 udp 2130706431 fd7a:115c:a1e0:0:0:0:0:102 50000 typ host\r\n"))
    }
}

extension SessionDescriptionTests {
    @Test func `should say why it refused an offer, in words a page can show`() {
        #expect(SessionDescription.Refusal.noVideo.description == "the offer has no video")
        #expect(SessionDescription.Refusal.noH264.description
            == "the offer has no High-profile H.264 in packetization mode 1, the only video baguette sends")
        #expect(SessionDescription.Refusal.noICECredentials.description == "the offer has no ICE username or password")
        #expect(SessionDescription.Refusal.noFingerprint.description == "the offer names no DTLS certificate fingerprint")
    }
}

/// The same offer with what Chrome adds for congestion control: the transport-wide
/// sequence extension (here id 3) and transport-cc feedback on the High profile.
private let offerWithTransportCC = chromeOffer
    .replacingOccurrences(
        of: "a=rtcp-mux\r\n",
        with: "a=rtcp-mux\r\na=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n"
            + "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n")
    .replacingOccurrences(of: "a=rtcp-fb:112 nack pli\r\n", with: "a=rtcp-fb:112 nack pli\r\na=rtcp-fb:112 transport-cc\r\n")

extension SessionDescriptionTests {
    @Test func `should read the offer's transport-wide sequence and abs-send-time extension ids`() throws {
        let offered = try SessionDescription(offer: offerWithTransportCC)
        #expect(offered.transportWideSequenceID == 3)
        #expect(offered.absSendTimeID == 2)
        let bare = try SessionDescription(offer: chromeOffer)
        #expect(bare.transportWideSequenceID == nil && bare.absSendTimeID == nil)
    }

    @Test func `should put its congestion control's lines in the answer, and none of its own`() throws {
        let description = try SessionDescription(offer: offerWithTransportCC)
        let lines = ["a=extmap:3 http://example/ext", "a=rtcp-fb:112 transport-cc"]

        let answer = description.answer(ice: ours, fingerprint: fingerprint, ssrc: 1, candidates: [], congestion: lines)

        #expect(answer.contains("a=setup:passive\r\na=extmap:3 http://example/ext\r\na=rtcp-fb:112 transport-cc\r\n"))
        #expect(!description.answer(ice: ours, fingerprint: fingerprint, ssrc: 1, candidates: []).contains("extmap"))
    }
}

@Suite("ICECredentials")
struct ICECredentialsTests {
    @Test func `should make fresh ICE credentials long enough for the spec, from ICE characters`() {
        let one = ICECredentials.fresh(), two = ICECredentials.fresh()
        let iceChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")

        #expect(one.ufrag.count >= 4 && one.password.count >= 22)
        #expect((one.ufrag + one.password).allSatisfy(iceChars.contains))
        #expect(one != two)
    }
}
