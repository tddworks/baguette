import Foundation

/// Congestion control the older way (REMB): every packet carries its send time
/// (abs-send-time), the browser estimates what it can receive and says so, and
/// that estimate is the target, between a floor and the starting bitrate.
public final class ReceiverEstimateControl: CongestionControl, @unchecked Sendable {
    private let lock = NSLock()
    private let extensionID: UInt8
    private let payloadType: UInt8
    private let floor: Int
    private let ceiling: Int
    private var estimate: Int

    public init(extensionID: UInt8, payloadType: UInt8, ceiling: Int, floor: Int = 300_000) {
        self.extensionID = extensionID
        self.payloadType = payloadType
        self.floor = floor
        self.ceiling = ceiling
        estimate = ceiling
    }

    public func answerLines() -> [String] {
        ["a=extmap:\(extensionID) \(SessionDescription.absSendTimeURI)", "a=rtcp-fb:\(payloadType) goog-remb"]
    }

    /// abs-send-time: seconds in 6.18 fixed point, 24 bits, wrapping every 64 s.
    public func extensions(at now: Int64) -> [RTPHeaderExtension] {
        let value = UInt32(truncatingIfNeeded: (now << 18) / 1_000_000) & 0xFF_FFFF
        return [RTPHeaderExtension(id: extensionID, data: [UInt8(value >> 16), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])]
    }

    public func sent(size: Int, at now: Int64) {}

    @discardableResult
    public func heard(_ feedback: RTCPFeedback, at now: Int64) -> BitrateCut? {
        guard case .bandwidthEstimate(let bitsPerSecond) = feedback else { return nil }
        lock.withLock { estimate = min(max(Int(clamping: bitsPerSecond), floor), ceiling) }
        return nil  // REMB supplies the target without delay or loss signals.
    }

    public var target: Int? { lock.withLock { estimate } }
}
