import Foundation

/// One RTP header extension element in the one-byte form (RFC 8285): an id
/// from 1 to 14 and 1 to 16 bytes of data. A WebRTC viewer carries the
/// transport-wide sequence number in one.
public struct RTPHeaderExtension: Equatable, Sendable {
    public let id: UInt8
    public let data: [UInt8]

    public init(id: UInt8, data: [UInt8]) {
        self.id = id
        self.data = data
    }
}

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
    /// One-byte header extensions; another profile's are skipped, not read.
    public let extensions: [RTPHeaderExtension]

    public init(
        marker: Bool, payloadType: UInt8, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data,
        extensions: [RTPHeaderExtension] = []
    ) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
        self.extensions = extensions
    }

    /// Nil for bytes that are too short or aren't RTP version 2.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        var offset = 12 + Int(bytes[0] & 0x0F) * 4
        var extensions: [RTPHeaderExtension] = []
        if bytes[0] & 0x10 != 0 {
            guard bytes.count >= offset + 4 else { return nil }
            let start = offset + 4
            offset = start + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) * 4
            guard bytes.count >= offset else { return nil }
            if bytes[start - 4] == 0xBE, bytes[start - 3] == 0xDE {
                extensions = Self.oneByteExtensions(bytes[start..<offset])
            }
        }
        guard bytes.count >= offset else { return nil }
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        ssrc = bytes[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
        payload = Data(bytes[offset...])
        self.extensions = extensions
    }

    /// RFC 8285 §4.2: each element is (id << 4 | length - 1) then its data;
    /// zero bytes are padding, and id 15 ends the list.
    private static func oneByteExtensions(_ block: ArraySlice<UInt8>) -> [RTPHeaderExtension] {
        var out: [RTPHeaderExtension] = []
        var at = block.startIndex
        while at < block.endIndex {
            let head = block[at]
            if head == 0 { at += 1; continue }
            let id = head >> 4, length = Int(head & 0x0F) + 1
            guard id != 15, at + 1 + length <= block.endIndex else { break }
            out.append(RTPHeaderExtension(id: id, data: Array(block[(at + 1)..<(at + 1 + length)])))
            at += 1 + length
        }
        return out
    }

    /// The packet on the wire: version 2, no padding or contributing sources,
    /// its one-byte extensions (padded to a word) when it has any, then the payload.
    public var data: Data {
        var out = Data([extensions.isEmpty ? 0x80 : 0x90, (marker ? 0x80 : 0) | payloadType & 0x7F])
        out.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
        out.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        if !extensions.isEmpty {
            var block = extensions.flatMap { [$0.id << 4 | UInt8($0.data.count - 1)] + $0.data }
            block += [UInt8](repeating: 0, count: (4 - block.count % 4) % 4)
            let words = block.count / 4
            out.append(contentsOf: [0xBE, 0xDE, UInt8(words >> 8), UInt8(words & 0xFF)] + block)
        }
        out.append(payload)
        return out
    }

    /// This packet resent on its own stream (RTX, RFC 4588 §4): the original
    /// sequence number ahead of the original payload, under the resend
    /// stream's payload type, sequence number and SSRC.
    public func retransmission(payloadType: UInt8, sequence: UInt16, ssrc: UInt32) -> RTPPacket {
        RTPPacket(
            marker: marker, payloadType: payloadType, sequence: sequence, timestamp: timestamp, ssrc: ssrc,
            payload: Data([UInt8(self.sequence >> 8), UInt8(self.sequence & 0xFF)]) + payload)
    }

    /// Whether `data` is RTCP sharing the port (packet types 200–206).
    public static func isRTCP(_ data: Data) -> Bool {
        data.count >= 2 && (200...206).contains(data[data.startIndex + 1])
    }
}
