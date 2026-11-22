import CoreMedia
import WebRTCKit

/// The codecs baguette encodes, by the kind a WebRTC session was answered
/// with — where the kit's `VideoCodec` (how a codec travels) meets
/// baguette's `Codec` (how it is encoded).
public enum Codecs {
    public static func of(_ kind: VideoCodec.Kind) -> any Codec {
        switch kind {
        case .h264: H264Codec()
        case .h265: HEVCCodec()
        }
    }

    /// What a socket stream encodes in, which has no offer to answer: HEVC when
    /// the browser asked for it (`h265`, or `auto`) and this Mac can encode it
    /// (`encodable`), else H.264.
    public static func asked(_ choice: CodecChoice?, encodable: Set<VideoCodec.Kind>) -> any Codec {
        switch choice {
        case .h265?, .auto?: of(encodable.contains(.h265) ? .h265 : .h264)
        case .h264?, nil: of(.h264)
        }
    }

    /// The kinds this Mac can encode, from the encoders it has (`among`).
    public static func encodable(among encoders: [CMVideoCodecType]) -> Set<VideoCodec.Kind> {
        Set([VideoCodec.Kind.h264, .h265].filter { encoders.contains(of($0).codecType) })
    }

    /// The kinds this Mac can encode, asked of VideoToolbox.
    public static var encodable: Set<VideoCodec.Kind> { encodable(among: VideoEncoders.installed()) }
}
