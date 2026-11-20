import Foundation

/// Congestion control as libwebrtc does it (transport-cc): every packet carries
/// a transport-wide sequence number, the browser reports when each arrived, and
/// `BandwidthEstimate` (GCC) sets the target from the reports.
public final class TransportWideControl: CongestionControl, @unchecked Sendable {
    private let lock = NSLock()
    private let extensionID: UInt8
    private let payloadType: UInt8
    private var sequence: UInt16 = 0
    private var history = SendHistory()
    private var estimate: BandwidthEstimate
    private var clock = FeedbackClock()

    public init(extensionID: UInt8, payloadType: UInt8, ceiling: Int) {
        self.extensionID = extensionID
        self.payloadType = payloadType
        estimate = BandwidthEstimate(ceiling: ceiling)
    }

    public func answerLines() -> [String] {
        ["a=extmap:\(extensionID) \(SessionDescription.transportWideSequenceURI)", "a=rtcp-fb:\(payloadType) transport-cc"]
    }

    public func extensions(at now: Int64) -> [RTPHeaderExtension] {
        lock.withLock { [RTPHeaderExtension(id: extensionID, data: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])] }
    }

    public func sent(size: Int, at now: Int64) {
        lock.withLock {
            history.sent(sequence: sequence, at: now, size: size)
            sequence &+= 1
        }
    }

    public func heard(_ feedback: RTCPFeedback, at now: Int64) {
        guard case .transportFeedback(let report) = feedback else { return }
        lock.withLock {
            estimate.update(with: history.outcomes(of: clock.unwrap(report), now: now), now: now)
        }
    }

    public var target: Int? { lock.withLock { estimate.target } }
}
