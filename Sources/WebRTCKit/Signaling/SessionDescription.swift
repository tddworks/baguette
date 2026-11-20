import Foundation

/// What a browser's WHEP offer (SDP, RFC 8866) tells a viewer, and the answer
/// it writes back. The offer must carry High-profile H.264 in packetization
/// mode 1 — what the encoder makes and `H264Packetizer` cuts — or it is
/// refused; a viewer never answers with another codec.
public struct SessionDescription: Equatable, Sendable {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case noVideo
        case noH264
        case noICECredentials
        case noFingerprint

        public var description: String {
            switch self {
            case .noVideo: "the offer has no video"
            case .noH264: "the offer has no High-profile H.264 in packetization mode 1, the only video baguette sends"
            case .noICECredentials: "the offer has no ICE username or password"
            case .noFingerprint: "the offer names no DTLS certificate fingerprint"
            }
        }
    }

    /// The browser's ICE credentials: it expects ours in the answer.
    public let browser: ICECredentials
    /// "sha-256 AB:CD:…": the certificate the browser's DTLS must present.
    public let browserFingerprint: String
    /// The media section's id, echoed in the answer's BUNDLE.
    public let mid: String
    public let payloadType: UInt8
    public let profileLevelID: String
    /// The header-extension id the offer gives the transport-wide sequence
    /// number, or nil when the browser offers no transport-cc congestion control
    /// (the extension, a one-byte id, and `transport-cc` feedback on our H.264).
    public let transportWideSequenceID: UInt8?
    /// The header-extension id the offer gives abs-send-time, which REMB needs;
    /// nil unless the browser also asks for `goog-remb` on our H.264.
    public let absSendTimeID: UInt8?
    /// The resend format (RTX, RFC 4588) the offer pairs with our H.264
    /// (`a=fmtp:<rtx> apt=<ours>`), or nil when it pairs none.
    public let rtxPayloadType: UInt8?

    public static let transportWideSequenceURI = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
    public static let absSendTimeURI = "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"

    public init(offer sdp: String) throws {
        let lines = sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let video = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { throw Refusal.noVideo }
        let next = lines[(video + 1)...].firstIndex { $0.hasPrefix("m=") } ?? lines.endIndex
        // Session-level lines (before the first m= line) apply unless the video section says
        // otherwise; another media section's lines — an audio `a=rtcp-fb:*` — never do.
        let sessionLevel = lines.prefix { !$0.hasPrefix("m=") }
        let section = Array(lines[(video + 1)..<next]) + Array(sessionLevel)
        func value(_ key: String) -> String? {
            section.first { $0.hasPrefix("a=\(key):") }.map { String($0.dropFirst(key.count + 3)) }
        }
        guard let ufrag = value("ice-ufrag"), let password = value("ice-pwd") else { throw Refusal.noICECredentials }
        guard let fingerprint = value("fingerprint") else { throw Refusal.noFingerprint }
        guard let (payloadType, profile) = Self.highProfileH264(in: section) else { throw Refusal.noH264 }
        browser = ICECredentials(ufrag: ufrag, password: password)
        browserFingerprint = fingerprint
        mid = value("mid") ?? "0"
        self.payloadType = payloadType
        profileLevelID = profile
        // a=extmap:<id>[/<direction>] <uri>: only an id a one-byte header
        // (RFC 8285 §4.2) carries — 1 to 14, all `RTPPacket` writes — that the
        // browser will receive (no `inactive` or `sendonly`, RFC 8285 §7), and
        // only with the feedback that makes it worth sending asked for on our
        // H.264, or on every format (`*`, RFC 4585 §4.2).
        func extensionID(_ uri: String, feedback: String) -> UInt8? {
            guard section.contains("a=rtcp-fb:\(payloadType) \(feedback)") || section.contains("a=rtcp-fb:* \(feedback)")
            else { return nil }
            return section.compactMap { line -> UInt8? in
                guard line.hasPrefix("a=extmap:"), line.hasSuffix(" " + uri) else { return nil }
                let mapping = line.dropFirst(9).prefix { $0 != " " }.split(separator: "/")
                guard let id = mapping.first.flatMap({ UInt8($0) }), (1...14).contains(id) else { return nil }
                let direction = mapping.count > 1 ? mapping[1] : "sendrecv"
                return direction == "sendrecv" || direction == "recvonly" ? id : nil
            }.first
        }
        transportWideSequenceID = extensionID(Self.transportWideSequenceURI, feedback: "transport-cc")
        absSendTimeID = extensionID(Self.absSendTimeURI, feedback: "goog-remb")
        let rtxFormats = Set(section.compactMap { line -> UInt8? in
            guard line.hasPrefix("a=rtpmap:"), line.lowercased().hasSuffix(" rtx/90000") else { return nil }
            return UInt8(line.dropFirst(9).prefix { $0 != " " })
        })
        rtxPayloadType = section.compactMap { line -> UInt8? in
            guard line.hasPrefix("a=fmtp:"), line.hasSuffix(" apt=\(payloadType)"),
                  let format = UInt8(line.dropFirst(7).prefix { $0 != " " }), rtxFormats.contains(format)
            else { return nil }
            return format
        }.first
    }

    /// The H.264 format the encoder can feed: High profile (profile_idc 0x64),
    /// packetization mode 1.
    private static func highProfileH264(in section: [String]) -> (UInt8, String)? {
        let h264 = section.compactMap { line -> UInt8? in
            guard line.hasPrefix("a=rtpmap:"), line.uppercased().hasSuffix(" H264/90000") else { return nil }
            return UInt8(line.dropFirst(9).prefix { $0 != " " })
        }
        for type in h264 {
            guard let fmtp = section.first(where: { $0.hasPrefix("a=fmtp:\(type) ") }) else { continue }
            let params = Dictionary(
                fmtp.split(separator: " ", maxSplits: 1).last!.split(separator: ";").compactMap { pair in
                    let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return kv.count == 2 ? (kv[0].lowercased(), kv[1]) : nil
                },
                uniquingKeysWith: { first, _ in first })
            guard params["packetization-mode"] == "1", let profile = params["profile-level-id"],
                  profile.lowercased().hasPrefix("64") else { continue }
            return (type, profile)
        }
        return nil
    }

    /// The answer: an ICE-lite agent at `candidates`, DTLS passive (the browser
    /// connects), sending this one H.264 format from `ssrc`, with the feedback
    /// the viewer acts on (NACK, PLI, FIR) and whatever lines its congestion
    /// control needs (`CongestionControl.answerLines`).
    public func answer(
        ice: ICECredentials, fingerprint: String, ssrc: UInt32, rtxSSRC: UInt32? = nil,
        candidates: [DatagramAddress], congestion: [String] = []
    ) -> String {
        let pt = payloadType
        // Resends on their own stream only when the offer has a format for them.
        let rtx = rtxSSRC.flatMap { stream in rtxPayloadType.map { (format: $0, ssrc: stream) } }
        var lines = [
            "v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=baguette", "t=0 0",
            "a=group:BUNDLE \(mid)", "a=ice-lite",
            "m=video 9 UDP/TLS/RTP/SAVPF \(pt)" + (rtx.map { " \($0.format)" } ?? ""), "c=IN IP4 0.0.0.0",
            "a=mid:\(mid)", "a=sendonly", "a=rtcp-mux",
            "a=ice-ufrag:\(ice.ufrag)", "a=ice-pwd:\(ice.password)",
            "a=fingerprint:\(fingerprint)", "a=setup:passive",
        ] + congestion
        lines += [
            "a=rtpmap:\(pt) H264/90000",
            "a=rtcp-fb:\(pt) nack", "a=rtcp-fb:\(pt) nack pli", "a=rtcp-fb:\(pt) ccm fir",
            "a=fmtp:\(pt) level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=\(profileLevelID)",
        ]
        if let rtx {
            lines += ["a=rtpmap:\(rtx.format) rtx/90000", "a=fmtp:\(rtx.format) apt=\(pt)"]
        }
        lines += ["a=msid:baguette screen", "a=ssrc:\(ssrc) cname:baguette"]
        if let rtx {
            lines += ["a=ssrc-group:FID \(ssrc) \(rtx.ssrc)", "a=ssrc:\(rtx.ssrc) cname:baguette"]
        }
        // Host candidates only (ICE-lite): type preference 126, in the given order.
        for (index, address) in candidates.enumerated() {
            lines.append("a=candidate:\(index + 1) 1 udp \(2_130_706_431 - index) \(Self.text(address.ip)) \(address.port) typ host")
        }
        lines += ["a=end-of-candidates", ""]
        return lines.joined(separator: "\r\n")
    }

    private static func text(_ ip: [UInt8]) -> String {
        guard ip.count == 16 else { return ip.map(String.init).joined(separator: ".") }
        return stride(from: 0, to: 16, by: 2)
            .map { String(UInt16(ip[$0]) << 8 | UInt16(ip[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }
}
