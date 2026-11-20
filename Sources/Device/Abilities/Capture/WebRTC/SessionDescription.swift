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
    /// number, or nil when the browser offers no transport-cc congestion control.
    public let transportWideSequenceID: UInt8?

    static let transportWideSequenceURI = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"

    public init(offer sdp: String) throws {
        let lines = sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let video = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { throw Refusal.noVideo }
        let next = lines[(video + 1)...].firstIndex { $0.hasPrefix("m=") } ?? lines.endIndex
        // Session-level lines apply unless the video section says otherwise.
        let section = Array(lines[(video + 1)..<next]) + Array(lines[..<video])
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
        transportWideSequenceID = section.compactMap { line -> UInt8? in
            // a=extmap:<id>[/<direction>] <uri>
            guard line.hasPrefix("a=extmap:"), line.hasSuffix(" " + Self.transportWideSequenceURI) else { return nil }
            return UInt8(line.dropFirst(9).prefix { $0.isNumber })
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
    /// the viewer acts on (NACK, PLI, FIR, and transport-cc when offered).
    public func answer(ice: ICECredentials, fingerprint: String, ssrc: UInt32, candidates: [DatagramAddress]) -> String {
        let pt = payloadType
        var lines = [
            "v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=baguette", "t=0 0",
            "a=group:BUNDLE \(mid)", "a=ice-lite",
            "m=video 9 UDP/TLS/RTP/SAVPF \(pt)", "c=IN IP4 0.0.0.0",
            "a=mid:\(mid)", "a=sendonly", "a=rtcp-mux",
            "a=ice-ufrag:\(ice.ufrag)", "a=ice-pwd:\(ice.password)",
            "a=fingerprint:\(fingerprint)", "a=setup:passive",
        ]
        if let id = transportWideSequenceID { lines.append("a=extmap:\(id) \(Self.transportWideSequenceURI)") }
        lines += [
            "a=rtpmap:\(pt) H264/90000",
            "a=rtcp-fb:\(pt) nack", "a=rtcp-fb:\(pt) nack pli", "a=rtcp-fb:\(pt) ccm fir",
        ]
        if transportWideSequenceID != nil { lines.append("a=rtcp-fb:\(pt) transport-cc") }
        lines += [
            "a=fmtp:\(pt) level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=\(profileLevelID)",
            "a=msid:baguette screen", "a=ssrc:\(ssrc) cname:baguette",
        ]
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
