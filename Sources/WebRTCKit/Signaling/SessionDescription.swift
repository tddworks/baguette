import Foundation

/// What a browser's WHEP offer (SDP, RFC 8866) tells a viewer, and the answer
/// it writes back. Every H.264 (packetization mode 1) and H.265 the offer
/// carries is read; `CodecChoice` picks the one sent — High-profile H.264
/// unless H.265 was asked for, is offered in Main profile and the owner can
/// send it — and an offer with nothing the owner can send is refused.
public struct SessionDescription: Equatable, Sendable {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case noVideo
        case noSendableVideo
        case noICECredentials
        case noFingerprint

        public var description: String {
            switch self {
            case .noVideo: "the offer has no video"
            case .noSendableVideo: "the offer has no video baguette can send: High-profile H.264 in packetization mode 1, or Main-profile H.265 when asked for"
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
    /// Every H.264 (packetization mode 1) and H.265 the offer carries, in its order.
    public let offered: [VideoCodec]
    /// The codec this session sends, as `CodecChoice` picked it.
    public let codec: VideoCodec
    public var payloadType: UInt8 { codec.payloadType }
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
    /// The addresses the browser's offer gives for itself (`a=candidate`), in
    /// its order: UDP, component 1, written as an IP. An mDNS name (`….local`)
    /// can't be checked from here and is left out; an offer posted before the
    /// browser gathered has none.
    public let candidates: [DatagramAddress]

    public static let transportWideSequenceURI = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
    public static let absSendTimeURI = "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"

    /// `rtx: false` takes no resend format even when the offer pairs one, so
    /// resends go as they were sent — the bench's baseline (`?rtx=off`).
    /// `asked` / `sendable`: what the owner asked for (`?codec=`) and what its
    /// encoder can make; by default H.264 only, as before H.265 existed.
    public init(offer sdp: String, rtx: Bool = true, asked: CodecChoice? = nil,
                sendable: Set<VideoCodec.Kind> = [.h264]) throws {
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
        let offered = Self.videoCodecs(in: section)
        guard let codec = CodecChoice.codec(asked: asked, offered: offered, sendable: sendable) else {
            throw Refusal.noSendableVideo
        }
        let payloadType = codec.payloadType
        browser = ICECredentials(ufrag: ufrag, password: password)
        browserFingerprint = fingerprint
        mid = value("mid") ?? "0"
        self.offered = offered
        self.codec = codec
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
        candidates = section.compactMap(Self.candidate)
        rtxPayloadType = !rtx ? nil : section.compactMap { line -> UInt8? in
            guard line.hasPrefix("a=fmtp:"), line.hasSuffix(" apt=\(payloadType)"),
                  let format = UInt8(line.dropFirst(7).prefix { $0 != " " }), rtxFormats.contains(format)
            else { return nil }
            return format
        }.first
    }

    /// Every H.264 in packetization mode 1 and every H.265 the section offers,
    /// with what its `fmtp` says (RFC 7798's defaults where H.265's is silent:
    /// profile 1, level 93, tier 0).
    private static func videoCodecs(in section: [String]) -> [VideoCodec] {
        func parameters(_ type: UInt8) -> [String: String] {
            guard let fmtp = section.first(where: { $0.hasPrefix("a=fmtp:\(type) ") }) else { return [:] }
            return Dictionary(
                fmtp.split(separator: " ", maxSplits: 1).last!.split(separator: ";").compactMap { pair in
                    let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return kv.count == 2 ? (kv[0].lowercased(), kv[1]) : nil
                },
                uniquingKeysWith: { first, _ in first })
        }
        return section.compactMap { line -> VideoCodec? in
            guard line.hasPrefix("a=rtpmap:"), let type = UInt8(line.dropFirst(9).prefix { $0 != " " }) else { return nil }
            let name = line.uppercased()
            let params = parameters(type)
            if name.hasSuffix(" H264/90000") {
                guard params["packetization-mode"] == "1", let profile = params["profile-level-id"] else { return nil }
                return .h264(payloadType: type, profileLevelID: profile)
            }
            if name.hasSuffix(" H265/90000") {
                return .h265(payloadType: type, profileID: params["profile-id"].flatMap(Int.init) ?? 1,
                             levelID: params["level-id"].flatMap(Int.init) ?? 93,
                             tier: params["tier-flag"].flatMap(Int.init) ?? 0)
            }
            return nil
        }
    }

    /// The answer: an ICE-lite agent at `candidates`, DTLS passive (the browser
    /// connects), sending its one chosen codec from `ssrc`, with the feedback
    /// the viewer acts on (NACK, PLI, FIR) and whatever lines its congestion
    /// control needs (`CongestionControl.answerLines`).
    public func answer(
        ice: ICECredentials, fingerprint: String, ssrc: UInt32, rtxSSRC: UInt32? = nil,
        candidates: [DatagramAddress], reflexive: DatagramAddress? = nil, relay: DatagramAddress? = nil,
        congestion: [String] = [], lite: Bool = true
    ) -> String {
        let pt = payloadType
        // Resends on their own stream only when the offer has a format for them.
        let rtx = rtxSSRC.flatMap { stream in rtxPayloadType.map { (format: $0, ssrc: stream) } }
        var lines = [
            "v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=baguette", "t=0 0",
            "a=group:BUNDLE \(mid)",
        ] + (lite ? ["a=ice-lite"] : []) + [
            "m=video 9 UDP/TLS/RTP/SAVPF \(pt)" + (rtx.map { " \($0.format)" } ?? ""), "c=IN IP4 0.0.0.0",
            "a=mid:\(mid)", "a=sendonly", "a=rtcp-mux",
            "a=ice-ufrag:\(ice.ufrag)", "a=ice-pwd:\(ice.password)",
            "a=fingerprint:\(fingerprint)", "a=setup:passive",
        ] + congestion
        lines += [
            "a=rtpmap:\(pt) \(codec.rtpmap)",
            "a=rtcp-fb:\(pt) nack", "a=rtcp-fb:\(pt) nack pli", "a=rtcp-fb:\(pt) ccm fir",
            "a=fmtp:\(pt) \(codec.fmtp)",
        ]
        if let rtx {
            lines += ["a=rtpmap:\(rtx.format) rtx/90000", "a=fmtp:\(rtx.format) apt=\(pt)"]
        }
        lines += ["a=msid:baguette screen", "a=ssrc:\(ssrc) cname:baguette"]
        if let rtx {
            lines += ["a=ssrc-group:FID \(ssrc) \(rtx.ssrc)", "a=ssrc:\(rtx.ssrc) cname:baguette"]
        }
        // Host candidates (type preference 126), in the given order; then the
        // address a STUN server saw (server-reflexive, 100), its base left out
        // (`raddr 0.0.0.0`) so the answer doesn't name the Mac's private one.
        for (index, address) in candidates.enumerated() {
            lines.append("a=candidate:\(index + 1) 1 udp \(2_130_706_431 - index) \(Self.text(address.ip)) \(address.port) typ host")
        }
        if let reflexive {
            lines.append("a=candidate:\(candidates.count + 1) 1 udp \(100 << 24 | 65_535 << 8 | 255) "
                + "\(Self.text(reflexive.ip)) \(reflexive.port) typ srflx raddr 0.0.0.0 rport 0")
        }
        // The address a TURN server relays at (type preference 0): the last resort.
        if let relay {
            lines.append("a=candidate:\(candidates.count + (reflexive == nil ? 1 : 2)) 1 udp \(65_535 << 8 | 255) "
                + "\(Self.text(relay.ip)) \(relay.port) typ relay raddr 0.0.0.0 rport 0")
        }
        lines += ["a=end-of-candidates", ""]
        return lines.joined(separator: "\r\n")
    }

    /// `a=candidate:<foundation> <component> <transport> <priority> <address> <port> typ <type> …`
    private static func candidate(_ line: String) -> DatagramAddress? {
        guard line.hasPrefix("a=candidate:") else { return nil }
        let fields = line.dropFirst(12).split(separator: " ").map(String.init)
        guard fields.count >= 6, fields[1] == "1", fields[2].lowercased() == "udp",
              let port = UInt16(fields[5]), let ip = address(fields[4]) else { return nil }
        return DatagramAddress(ip: ip, port: port)
    }

    /// An IPv4 or IPv6 literal's bytes; nil for a name.
    private static func address(_ text: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    private static func text(_ ip: [UInt8]) -> String {
        guard ip.count == 16 else { return ip.map(String.init).joined(separator: ".") }
        return stride(from: 0, to: 16, by: 2)
            .map { String(UInt16(ip[$0]) << 8 | UInt16(ip[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }
}
