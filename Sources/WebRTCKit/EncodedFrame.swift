import Foundation

/// One H.264 picture to send: its NAL units, each prefixed by its 4-byte
/// length (AVCC), whether it is a keyframe, and — for a keyframe — the SPS and
/// PPS the browser needs to decode it, sent ahead of it.
public struct EncodedFrame: Equatable, Sendable {
    public let avcc: Data
    public let isKeyframe: Bool
    public let parameterSets: [Data]

    public init(avcc: Data, isKeyframe: Bool, parameterSets: [Data] = []) {
        self.avcc = avcc
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
    }
}
