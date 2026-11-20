import Foundation

/// What a browser asks of a viewer in its RTCP (RFC 4585, RFC 5104, REMB):
/// a keyframe after a lost picture, packets to resend, or the bitrate it can
/// take. Receiver reports and the rest are read past, never acted on.
public enum RTCPFeedback: Equatable, Sendable {
    /// PLI or FIR: the browser can't decode until the next keyframe.
    case keyframeRequest
    /// Generic NACK: these sequence numbers never arrived.
    case lost([UInt16])
    /// REMB: what the browser estimates it can receive.
    case bandwidthEstimate(bitsPerSecond: UInt64)
    /// transport-cc: when each transport-wide sequence number arrived.
    case transportFeedback(TransportFeedback)

    private static let rtpfb: UInt8 = 205   // transport-layer feedback
    private static let psfb: UInt8 = 206    // payload-specific feedback

    /// Every feedback in a compound RTCP packet, in order; a packet whose
    /// length runs past the end stops the read.
    public static func parse(_ compound: Data) -> [RTCPFeedback] {
        let bytes = [UInt8](compound)
        var out: [RTCPFeedback] = []
        var at = 0
        while at + 4 <= bytes.count {
            let end = at + 4 + (Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])) * 4
            guard end <= bytes.count else { break }
            if let feedback = read(format: bytes[at] & 0x1F, type: bytes[at + 1], body: Array(bytes[at + 4..<end])) {
                out.append(feedback)
            }
            at = end
        }
        return out
    }

    /// `body` starts at the sender SSRC; feedback control information follows
    /// the media SSRC, at byte 8.
    private static func read(format: UInt8, type: UInt8, body: [UInt8]) -> RTCPFeedback? {
        guard body.count >= 8 else { return nil }
        let fci = Array(body[8...])
        switch (type, format) {
        case (psfb, 1), (psfb, 4):
            return .keyframeRequest
        case (rtpfb, 15):
            return TransportFeedback(fci: fci).map(RTCPFeedback.transportFeedback)
        case (rtpfb, 1):
            let lost = stride(from: 0, to: fci.count - fci.count % 4, by: 4).flatMap { i -> [UInt16] in
                let pid = UInt16(fci[i]) << 8 | UInt16(fci[i + 1])
                let mask = UInt16(fci[i + 2]) << 8 | UInt16(fci[i + 3])
                return [pid] + (0..<16).filter { mask & (1 << $0) != 0 }.map { pid &+ UInt16($0) &+ 1 }
            }
            return lost.isEmpty ? nil : .lost(lost)
        case (psfb, 15):
            guard fci.count >= 8, fci[0..<4].elementsEqual("REMB".utf8) else { return nil }
            let exponent = UInt64(fci[5] >> 2)
            let mantissa = UInt64(fci[5] & 0x03) << 16 | UInt64(fci[6]) << 8 | UInt64(fci[7])
            return .bandwidthEstimate(bitsPerSecond: mantissa << exponent)
        default:
            return nil
        }
    }
}
