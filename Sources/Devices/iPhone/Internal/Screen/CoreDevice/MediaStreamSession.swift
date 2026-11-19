import Foundation

/// One live-screen session with a phone, as CoreDevice's answer describes
/// it: where the phone streams from, and the two RTP sources (the phone's,
/// and ours as the receiver). The words around it — the request that
/// starts it, the offer's clock, the goodbye that ends it — are here too.
struct MediaStreamSession: Equatable, Sendable {
    let phoneHost: String
    let phonePort: UInt16
    let phoneSource: UInt32
    let ourSource: UInt32

    init(phoneHost: String, phonePort: UInt16, phoneSource: UInt32, ourSource: UInt32) {
        self.phoneHost = phoneHost
        self.phonePort = phonePort
        self.phoneSource = phoneSource
        self.ourSource = ourSource
    }

    /// The session in CoreDevice's `StartResponse` (as JSON), or nil when
    /// it doesn't say where the stream comes from.
    init?(answer: [String: Any]) {
        guard let connection = answer["connection"] as? [String: Any],
              let config = connection["streamConfig"] as? [String: Any],
              let host = config["SourceIP"] as? String,
              let port = (config["SourcePort"] as? NSNumber)?.uint16Value,
              let phoneSource = (config["LocalSSRC"] as? NSNumber)?.uint32Value,
              let ourSource = (config["RemoteSSRC"] as? NSNumber)?.uint32Value
        else { return nil }
        self.init(phoneHost: host, phonePort: port, phoneSource: phoneSource, ourSource: ourSource)
    }

    /// The negotiator's answer in CoreDevice's `StartResponse` (as JSON) —
    /// what AVConference's negotiator takes back after its own offer — or
    /// nil when CoreDevice sent none.
    static func negotiatorAnswer(in answer: [String: Any]) -> Data? {
        (answer["negotiatorAnswer"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// CoreDevice's `StartRequest`, as JSON: the main display's video, sent
    /// to `receiverIP`:`port` (this Mac's end of the tunnel), with our offer.
    static func startRequest(offer: Data, receiverIP: String, port: UInt16, session: UUID = UUID()) -> [String: Any] {
        [
            "timeout": 20, "type": "video", "direction": "output",
            "negotiatorOffer": offer.base64EncodedString(), "clientSupportedFeatures": 140,
            "receiverIP": receiverIP, "receiverPort": Int(port),
            "options": [
                "CoreDeviceVideoDisplayMode": ["string": "DisplayByID"],
                "VideoStreamForDisplayID": ["int": 1],
                "AVCMediaStreamNegotiatorAccessNetworkType": ["int": 1],
                "AVCMediaStreamNegotiatorTransportProtocolType": ["int": 2],
                "avcMediaStreamOptionClientSessionID": ["uuid": session.uuidString],
            ],
        ]
    }

    /// `date` as an NTP timestamp (seconds since 1900, 32.32 fixed point).
    static func ntpTime(_ date: Date) -> UInt64 {
        let now = date.timeIntervalSince1970 + 2_208_988_800
        return UInt64(now) << 32 | UInt64((now - now.rounded(.down)) * 4_294_967_296)
    }

    /// An RTCP BYE from our source: the phone can stop sending at once.
    static func goodbye(from reporter: UInt32) -> Data {
        [0x81CB_0001, reporter].map(\.bigEndian).withUnsafeBytes { Data($0) }
    }
}
