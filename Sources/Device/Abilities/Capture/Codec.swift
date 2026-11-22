import CoreMedia
import Foundation

/// A video codec as baguette encodes it — the only four things that differ
/// between codecs: which encoder to open and in which profile, the decoder
/// configuration record its encoder makes (VideoToolbox hands it back, made:
/// nothing builds one), and the parameter sets inside it — what a WebRTC
/// sender puts ahead of a keyframe. Everything else (sessions, keyframes,
/// tuning, the stream, the sender) is codec-blind; a codec is one new type.
/// Design: docs/features/webrtc/hevc.md#2--what-changes-in-baguette--the-codec-from-first-principles.
public protocol Codec: Sendable {
    /// The VideoToolbox encoder to open.
    var codecType: CMVideoCodecType { get }
    /// The profile it encodes in.
    var profile: CompressionProperty { get }
    /// The atom a keyframe's format description carries its record under.
    var recordAtom: String { get }
    /// The parameter sets in its record, in sending order; nil for a record that isn't one.
    func parameterSets(record: Data) -> [Data]?
}

/// H.264, High profile: the `avcC` record, SPS then PPS.
public struct H264Codec: Codec {
    public let codecType: CMVideoCodecType = kCMVideoCodecType_H264
    public let profile: CompressionProperty = .highProfileAutoLevel
    public let recordAtom = "avcC"

    public init() {}

    public func parameterSets(record: Data) -> [Data]? {
        AVCCParameterSets.parse(avcC: record).map { $0.sps + $0.pps }
    }
}

/// H.265, Main profile: the `hvcC` record, VPS then SPS then PPS.
public struct HEVCCodec: Codec {
    public let codecType: CMVideoCodecType = kCMVideoCodecType_HEVC
    public let profile: CompressionProperty = .hevcMainAutoLevel
    public let recordAtom = "hvcC"

    public init() {}

    public func parameterSets(record: Data) -> [Data]? {
        HVCCParameterSets.parse(hvcC: record)?.inSendingOrder
    }
}
