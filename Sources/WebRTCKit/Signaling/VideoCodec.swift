import Foundation

/// A video codec a browser offers, as its offer numbers and describes it:
/// H.264 by its profile-level-id, H.265 by its profile, level and tier
/// (RFC 7798). Answers what the sender needs of it: its kind, and the
/// packetizer that cuts its pictures.
public enum VideoCodec: Equatable, Hashable, Sendable {
    case h264(payloadType: UInt8, profileLevelID: String)
    case h265(payloadType: UInt8, profileID: Int, levelID: Int, tier: Int)

    public enum Kind: Hashable, Sendable { case h264, h265 }

    public var kind: Kind {
        switch self {
        case .h264: .h264
        case .h265: .h265
        }
    }

    public var payloadType: UInt8 {
        switch self {
        case let .h264(payloadType, _), let .h265(payloadType, _, _, _): payloadType
        }
    }

    /// High-profile H.264 (`profile_idc` 100, `64…`) or Main-profile H.265
    /// (`profile-id` 1): what the encoder makes.
    public var isSendableProfile: Bool {
        switch self {
        case let .h264(_, profileLevelID): profileLevelID.lowercased().hasPrefix("64")
        case let .h265(_, profileID, _, _): profileID == 1
        }
    }

    /// Its `a=rtpmap` encoding name and clock rate.
    public var rtpmap: String {
        switch self {
        case .h264: "H264/90000"
        case .h265: "H265/90000"
        }
    }

    /// Its `a=fmtp` parameters, as the answer gives them: what the sender sends.
    public var fmtp: String {
        switch self {
        case let .h264(_, profileLevelID):
            "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=\(profileLevelID)"
        case let .h265(_, profileID, levelID, tier):
            "level-id=\(levelID);profile-id=\(profileID);tier-flag=\(tier);tx-mode=SRST"
        }
    }

    public var packetizer: any RTPPacketizer {
        switch self {
        case .h264: H264Packetizer()
        case .h265: H265Packetizer()
        }
    }
}
