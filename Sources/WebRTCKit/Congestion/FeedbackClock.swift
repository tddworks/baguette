import Foundation

/// The browser's clock as its transport-cc reports tell it: each carries a
/// reference time of 24 signed bits in 64 ms steps, which wraps every ~12.4
/// days. Every report is moved onto one unbroken timeline — the one nearest
/// the report before it — so arrivals either side of a wrap stay in order
/// (libwebrtc's TransportFeedbackAdapter does the same).
struct FeedbackClock: Sendable {
    private static let period: Int64 = 0x100_0000 * 64_000
    private var last: Int64?

    /// `report` with its reference and arrivals on the unbroken timeline.
    mutating func unwrap(_ report: TransportFeedback) -> TransportFeedback {
        let reference: Int64
        if let last {
            // The step from the last reference, taken the short way round.
            var step = (report.reference - last) % Self.period
            if step >= Self.period / 2 { step -= Self.period }
            if step < -Self.period / 2 { step += Self.period }
            reference = last + step
        } else {
            reference = report.reference
        }
        last = reference
        let shift = reference - report.reference
        guard shift != 0 else { return report }
        return TransportFeedback(
            feedbackCount: report.feedbackCount, reference: reference,
            arrivals: report.arrivals.map { .init(sequence: $0.sequence, microseconds: $0.microseconds.map { $0 + shift }) })
    }
}
