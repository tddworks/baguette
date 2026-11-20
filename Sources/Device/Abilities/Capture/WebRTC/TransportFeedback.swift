import Foundation

/// A browser's transport-cc report (draft-holmer-rmcat-transport-wide-cc-
/// extensions-01 §3.1): for a run of transport-wide sequence numbers, whether
/// each packet arrived and when, on the browser's clock. The viewer's bandwidth
/// estimate is built from these. Arrival times are in microseconds from the
/// browser's reference time zero; only their differences mean anything.
public struct TransportFeedback: Equatable, Sendable {
    public struct Arrival: Equatable, Sendable {
        public let sequence: UInt16
        /// Nil when the packet hasn't arrived (yet).
        public let microseconds: Int64?

        public init(sequence: UInt16, microseconds: Int64?) {
            self.sequence = sequence
            self.microseconds = microseconds
        }
    }

    /// Counts the browser's reports, so a lost or reordered one shows.
    public let feedbackCount: UInt8
    public let arrivals: [Arrival]

    public init(feedbackCount: UInt8, arrivals: [Arrival]) {
        self.feedbackCount = feedbackCount
        self.arrivals = arrivals
    }

    private enum Status { case missing, small, large }

    /// Nil for a report whose chunks or deltas run past its end.
    public init?(fci bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        let base = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let count = Int(bytes[2]) << 8 | Int(bytes[3])
        // 24-bit signed, in multiples of 64 ms.
        var reference = Int32(bytes[4]) << 16 | Int32(bytes[5]) << 8 | Int32(bytes[6])
        if reference & 0x80_0000 != 0 { reference -= 0x100_0000 }
        var at = 8
        var statuses: [Status] = []
        while statuses.count < count {
            guard at + 2 <= bytes.count else { return nil }
            let chunk = UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            at += 2
            if chunk & 0x8000 == 0 {
                // Run length: one symbol, repeated.
                guard let status = Self.status(UInt8(chunk >> 13 & 0x3)) else { return nil }
                statuses += Array(repeating: status, count: Int(chunk & 0x1FFF))
            } else if chunk & 0x4000 == 0 {
                // Status vector of fourteen 1-bit symbols: received means a small delta.
                statuses += (0..<14).map { chunk >> (13 - $0) & 1 == 1 ? .small : .missing }
            } else {
                // Status vector of seven 2-bit symbols.
                for i in 0..<7 {
                    guard let status = Self.status(UInt8(chunk >> (12 - 2 * i) & 0x3)) else { return nil }
                    statuses.append(status)
                }
            }
        }
        var time = Int64(reference) * 64_000
        var arrivals: [Arrival] = []
        for (offset, status) in statuses.prefix(count).enumerated() {
            let sequence = base &+ UInt16(truncatingIfNeeded: offset)
            switch status {
            case .missing:
                arrivals.append(Arrival(sequence: sequence, microseconds: nil))
                continue
            case .small:
                guard at + 1 <= bytes.count else { return nil }
                time += Int64(bytes[at]) * 250
                at += 1
            case .large:
                guard at + 2 <= bytes.count else { return nil }
                time += Int64(Int16(bitPattern: UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]))) * 250
                at += 2
            }
            arrivals.append(Arrival(sequence: sequence, microseconds: time))
        }
        feedbackCount = bytes[7]
        self.arrivals = arrivals
    }

    /// 0 not received, 1 small delta, 2 large or negative delta; 3 is reserved.
    private static func status(_ symbol: UInt8) -> Status? {
        switch symbol {
        case 0: .missing
        case 1: .small
        case 2: .large
        default: nil
        }
    }
}
