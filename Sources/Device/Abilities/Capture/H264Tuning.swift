import Foundation

/// Encoder-latency knobs for the H.264 (AVCC) stream, as a pure value so
/// the "what config do we want" decision is testable apart from the
/// irreducible VideoToolbox calls that apply it (`VideoEncoder`). The
/// `lowLatency` preset targets frames stalling in the browser's WebCodecs
/// decoder queue: no reordering + low-latency rate control signal a
/// minimal DPB, so the decoder stops holding frames back.
public struct H264Tuning: Equatable, Sendable {
    /// VideoToolbox real-time encode path.
    public let realTime: Bool

    /// B-frames off — reordering adds decode-side buffering latency.
    public let allowFrameReordering: Bool

    /// Frames the encoder may hold before emitting. `0` = emit immediately;
    /// `nil` = VideoToolbox default.
    public let maxFrameDelayCount: Int?

    /// VideoToolbox's low-latency rate-control mode (the FaceTime /
    /// screen-share path) — shrinks the pipeline and signals a minimal DPB.
    public let lowLatencyRateControl: Bool

    /// Seconds between forced IDRs; a long GOP keeps big keyframes rare.
    public let keyFrameIntervalSeconds: Int

    public static let lowLatency = H264Tuning(
        realTime: true,
        allowFrameReordering: false,
        maxFrameDelayCount: 0,
        lowLatencyRateControl: true,
        keyFrameIntervalSeconds: 5
    )

    /// The preset for a session that must accept every property it is
    /// given: low-latency rate control already forbids lookahead and
    /// B-frames, and `MaxFrameDelayCount` is left out because not every
    /// encoder supports it.
    public static let strict = H264Tuning(
        realTime: true,
        allowFrameReordering: false,
        maxFrameDelayCount: nil,
        lowLatencyRateControl: true,
        keyFrameIntervalSeconds: 5
    )

    /// Frames between forced IDRs at a given capture rate. Guards fps 0 so
    /// a misconfigured stream still forces periodic keyframes.
    public func maxKeyFrameInterval(fps: Int) -> Int {
        keyFrameIntervalSeconds * max(1, fps)
    }

    public init(realTime: Bool, allowFrameReordering: Bool, maxFrameDelayCount: Int?, lowLatencyRateControl: Bool, keyFrameIntervalSeconds: Int) {
        self.realTime = realTime
        self.allowFrameReordering = allowFrameReordering
        self.maxFrameDelayCount = maxFrameDelayCount
        self.lowLatencyRateControl = lowLatencyRateControl
        self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
    }
}

/// One setting an H.264 compression session is given — VideoToolbox's
/// `kVTCompressionPropertyKey_*`, as a value the tuning can be tested by.
public enum CompressionProperty: Equatable, Sendable {
    case realTime(Bool)
    /// High profile, the level chosen by the encoder.
    case highProfileAutoLevel
    case allowFrameReordering(Bool)
    case averageBitRate(Int)
    case expectedFrameRate(Int32)
    case maxKeyFrameInterval(Int)
    case maxFrameDelayCount(Int)
}

public extension H264Tuning {
    /// Everything a new session is given, in the order it is given — the
    /// codec's `profile` second, after real-time mode.
    func properties(bitrate: Int, fps: Int32, profile: CompressionProperty) -> [CompressionProperty] {
        var all: [CompressionProperty] = [
            .realTime(realTime), profile, .allowFrameReordering(allowFrameReordering),
            .averageBitRate(bitrate),
        ] + frameRateProperties(fps: fps)
        if let maxFrameDelayCount { all.append(.maxFrameDelayCount(maxFrameDelayCount)) }
        return all
    }

    /// What changes on a live session when its frame rate does: the
    /// expected rate, and the keyframe spacing that is counted in frames.
    func frameRateProperties(fps: Int32) -> [CompressionProperty] {
        [.expectedFrameRate(fps), .maxKeyFrameInterval(maxKeyFrameInterval(fps: Int(fps)))]
    }
}

