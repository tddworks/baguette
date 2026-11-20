import Foundation
import Mockable

/// A lower bitrate selected for the viewer, with the signal that limited it.
public struct BitrateCut: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// Delay above the link's floor, in microseconds.
        case queue(delay: Int64)
        case loss(Double)
    }

    public let at: Int64
    public let cause: Cause
    public let to: Int
}

/// How a WebRTC viewer learns how much the link to its browser can take, and
/// so what its encoder should aim for. One role, several methods the viewer
/// can't tell apart: transport-cc (`TransportWideControl`), REMB
/// (`ReceiverEstimateControl`) and none (`FixedBitrate`), picked per viewer by
/// `CongestionChoice`. The viewer stamps every packet with what its method
/// asks, reports it sent, hands it the browser's feedback, and retunes its
/// encoder to the target. Times are microseconds.
@Mockable
public protocol CongestionControl: AnyObject, Sendable {
    /// The SDP lines the answer needs for it (extensions, feedback).
    func answerLines() -> [String]
    /// What the next packet carries, sent `now`.
    func extensions(at now: Int64) -> [RTPHeaderExtension]
    /// That packet left, `size` bytes on the wire.
    func sent(size: Int, at now: Int64)
    /// A report from the browser and any diagnosed cut to the target.
    @discardableResult
    func heard(_ feedback: RTCPFeedback, at now: Int64) -> BitrateCut?
    /// The bitrate it wants, or nil when it has no opinion of its own.
    var target: Int? { get }
}
