import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// What baguette says to CoreDevice to start a phone's live screen, and
/// what it reads back: the request, where the phone streams from, the
/// offer's clock and the goodbye.
@Suite("MediaStreamSession")
struct MediaStreamSessionTests {
    @Test func `should ask CoreDevice for the main display's video, sent to this Mac`() throws {
        let session = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let request = MediaStreamSession.startRequest(
            offer: Data([1, 2, 3]), receiverIP: "fdd3:48cf:f69f::2", port: 50001, session: session)

        #expect(request["type"] as? String == "video")
        #expect(request["direction"] as? String == "output")
        #expect(request["timeout"] as? Int == 20)
        #expect(request["clientSupportedFeatures"] as? Int == 140)
        #expect(request["negotiatorOffer"] as? String == "AQID")
        #expect(request["receiverIP"] as? String == "fdd3:48cf:f69f::2")
        #expect(request["receiverPort"] as? Int == 50001)
        let options = try #require(request["options"] as? [String: [String: Any]])
        #expect(options["CoreDeviceVideoDisplayMode"]?["string"] as? String == "DisplayByID")
        #expect(options["VideoStreamForDisplayID"]?["int"] as? Int == 1)
        #expect(options["AVCMediaStreamNegotiatorAccessNetworkType"]?["int"] as? Int == 1)
        #expect(options["AVCMediaStreamNegotiatorTransportProtocolType"]?["int"] as? Int == 2)
        #expect(options["avcMediaStreamOptionClientSessionID"]?["uuid"] as? String == session.uuidString)
    }

    @Test func `should read where the phone streams from out of CoreDevice's answer`() {
        let answer: [String: Any] = ["connection": ["streamConfig": [
            "SourceIP": "fdd3:48cf:f69f::1", "SourcePort": NSNumber(value: 61000),
            "LocalSSRC": NSNumber(value: 0xE95D_3647 as UInt32), "RemoteSSRC": NSNumber(value: 7),
        ]]]

        #expect(MediaStreamSession(answer: answer) == MediaStreamSession(
            phoneHost: "fdd3:48cf:f69f::1", phonePort: 61000, phoneSource: 0xE95D_3647, ourSource: 7))
    }

    @Test func `should read no stream from an answer that doesn't say where it comes from`() {
        #expect(MediaStreamSession(answer: [:]) == nil)
        #expect(MediaStreamSession(answer: ["connection": ["streamConfig": ["SourceIP": "fdd3::1"]]]) == nil)
    }

    @Test func `should read the negotiator's answer out of CoreDevice's answer`() {
        let answer: [String: Any] = ["negotiatorAnswer": "AQID", "connection": [:] as [String: Any]]

        #expect(MediaStreamSession.negotiatorAnswer(in: answer) == Data([1, 2, 3]))
    }

    @Test func `should read no negotiator's answer when CoreDevice sent none`() {
        #expect(MediaStreamSession.negotiatorAnswer(in: ["connection": [:] as [String: Any]]) == nil)
        #expect(MediaStreamSession.negotiatorAnswer(in: ["negotiatorAnswer": "not base64!"]) == nil)
    }

    @Test func `should time the offer in NTP's seconds since 1900, the fraction in the low word`() {
        let unixEpoch = Date(timeIntervalSince1970: 0.5)

        #expect(MediaStreamSession.ntpTime(unixEpoch) == UInt64(2_208_988_800) << 32 | 0x8000_0000)
    }

    @Test func `should say goodbye as an RTCP BYE from our source`() {
        #expect(MediaStreamSession.goodbye(from: 0x0102_0304) == Data([0x81, 0xCB, 0x00, 0x01, 1, 2, 3, 4]))
    }
}
