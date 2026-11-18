import Foundation

/// Encoder-latency knobs for the H.264 (AVCC) stream, as a pure value so
/// the "what config do we want" decision is testable apart from the
/// irreducible VideoToolbox calls that apply it (`H264Encoder`). The
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
