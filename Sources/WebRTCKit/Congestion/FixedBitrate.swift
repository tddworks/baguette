import Foundation

/// No congestion control: nothing in the answer, nothing on the packets, no
/// target — the encoder stays where it started, or where `set_bitrate` put it.
public final class FixedBitrate: CongestionControl, @unchecked Sendable {
    public init() {}
    public func answerLines() -> [String] { [] }
    public func extensions(at now: Int64) -> [RTPHeaderExtension] { [] }
    public func sent(size: Int, at now: Int64) {}
    @discardableResult
    public func heard(_ feedback: RTCPFeedback, at now: Int64) -> BitrateCut? { nil }
    public var target: Int? { nil }
}
