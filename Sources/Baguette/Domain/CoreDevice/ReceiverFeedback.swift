import Foundation

/// What a receiver tells the phone while its screen streams, and when —
/// the RTCP Device Hub sends back:
///
/// - a receiver report every second (the phone stops after 20 s without);
/// - an acknowledgement as each picture's last packet arrives;
/// - an `RCTL` every 50 ms once packets flow: pictures and packets so far,
///   and a millisecond clock, which the phone's encoder steers by;
/// - a picture-loss indication every 300 ms while a keyframe is wanted
///   (a request can be lost too).
///
/// Tell it what was heard (`heard`) and what time it is (`due`); send what
/// it answers. Times are seconds since the stream opened.
struct ReceiverFeedback: Sendable {
    let reporter: UInt32
    let source: UInt32

    private var highest: UInt32 = 0
    private var firstSequence: UInt16?
    private var lastSequence: UInt16 = 0
    private var pictures: UInt16 = 0
    private var lastReport: TimeInterval?
    private var lastControl: TimeInterval?
    private var lastKeyframeRequest: TimeInterval?

    init(reporter: UInt32, source: UInt32) {
        self.reporter = reporter
        self.source = source
    }

    /// Takes note of a packet; answers the acknowledgement of a finished picture.
    mutating func heard(_ packet: RTPPacket) -> [Data] {
        highest = max(highest, highest & 0xFFFF_0000 | UInt32(packet.sequence))
        if firstSequence == nil { firstSequence = packet.sequence }
        lastSequence = packet.sequence
        guard packet.marker else { return [] }
        pictures &+= 1
        return [RTCPReceiverReport.pictureReceived(reporter: reporter, timestamp: packet.timestamp)]
    }

    /// The reports due at `now`.
    mutating func due(at now: TimeInterval, wantingKeyframe: Bool) -> [Data] {
        var reports: [Data] = []
        if Self.elapsed(since: lastReport, at: now, atLeast: 1) {
            reports.append(RTCPReceiverReport(reporter: reporter, source: source, highestSequence: highest).bytes)
            lastReport = now
        }
        if let firstSequence, Self.elapsed(since: lastControl, at: now, atLeast: 0.05) {
            reports.append(RTCPReceiverReport.receiverControl(
                reporter: reporter, clock: UInt16(truncatingIfNeeded: Int((now * 1000).rounded())),
                pictures: pictures, packets: lastSequence &- firstSequence))
            lastControl = now
        }
        if wantingKeyframe, Self.elapsed(since: lastKeyframeRequest, at: now, atLeast: 0.3) {
            reports.append(RTCPReceiverReport.pictureLossIndication(reporter: reporter, source: source))
            lastKeyframeRequest = now
        }
        return reports
    }

    /// Whether `interval` has passed since `last` — always, when never.
    /// A millisecond of slack keeps a 50 ms tick from slipping on rounding.
    private static func elapsed(since last: TimeInterval?, at now: TimeInterval, atLeast interval: TimeInterval) -> Bool {
        guard let last else { return true }
        return now - last >= interval - 0.000_5
    }
}
