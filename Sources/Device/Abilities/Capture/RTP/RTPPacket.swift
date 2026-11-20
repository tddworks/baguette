import Foundation

/// One RTP packet (RFC 3550): its header, and the payload past any
/// contributing sources and header extension. Read from a phone's screen,
/// written to a WebRTC viewer.
public struct RTPPacket: Equatable, Sendable {
    public let marker: Bool
    public let payloadType: UInt8
    public let sequence: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let payload: Data

    public init(marker: Bool, payloadType: UInt8, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// Nil for bytes that are too short or aren't RTP version 2.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        var offset = 12 + Int(bytes[0] & 0x0F) * 4
        if bytes[0] & 0x10 != 0 {
            guard bytes.count >= offset + 4 else { return nil }
            offset += 4 + Int(bytes[offset + 2]) << 8 * 4 + Int(bytes[offset + 3]) * 4
        }
        guard bytes.count >= offset else { return nil }
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        ssrc = bytes[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
        payload = Data(bytes[offset...])
    }

    /// The packet on the wire: version 2, no padding, extension or
    /// contributing sources, then the payload.
    public var data: Data {
        var out = Data([0x80, (marker ? 0x80 : 0) | payloadType & 0x7F])
        out.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
        out.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        out.append(payload)
        return out
    }

    /// Whether `data` is RTCP sharing the port (packet types 200–206).
    public static func isRTCP(_ data: Data) -> Bool {
        data.count >= 2 && (200...206).contains(data[data.startIndex + 1])
    }
}
