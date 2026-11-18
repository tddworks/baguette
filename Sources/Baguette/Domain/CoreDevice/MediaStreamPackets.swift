import Foundation

// A physical phone's live screen arrives as an RTP stream (RFC 3550) of
// H.264 (RFC 6184), unencrypted, over the CoreDevice tunnel. These values
// turn its packets back into frames; the socket and decoder are elsewhere.
// Research: docs/features/real-devices/design.md.

/// One RTP packet: its header, and the payload past any contributing
/// sources and header extension.
struct RTPPacket: Equatable, Sendable {
    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    /// Nil for bytes that are too short or aren't RTP version 2.
    init?(_ data: Data) {
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

    /// Whether `data` is RTCP sharing the port (packet types 200–206).
    static func isRTCP(_ data: Data) -> Bool {
        data.count >= 2 && (200...206).contains(data[data.startIndex + 1])
    }
}

/// The NAL units of one picture, as the phone encoded them.
struct AccessUnit: Equatable, Sendable {
    let nalUnits: [Data]
    let timestamp: UInt32

    private static func type(_ nal: Data) -> UInt8 { (nal.first ?? 0) & 0x1F }

    /// An IDR picture: decodable on its own.
    var isKeyframe: Bool { nalUnits.contains { Self.type($0) == 5 } }

    /// The avcC record a decoder is configured with, when this unit
    /// carries both parameter sets (the phone sends them before each IDR).
    var decoderDescription: Data? {
        guard let sps = nalUnits.first(where: { Self.type($0) == 7 }), sps.count >= 4,
              let pps = nalUnits.first(where: { Self.type($0) == 8 })
        else { return nil }
        let s = [UInt8](sps), p = [UInt8](pps)
        var record: [UInt8] = [1, s[1], s[2], s[3], 0xFF, 0xE1]
        record += [UInt8(s.count >> 8), UInt8(s.count & 0xFF)] + s
        record += [1, UInt8(p.count >> 8), UInt8(p.count & 0xFF)] + p
        return Data(record)
    }

    /// The picture's NAL units, each behind a four-byte length — the
    /// frame a decoder configured from `decoderDescription` takes.
    var lengthPrefixedFrame: Data {
        var frame = Data()
        for nal in nalUnits where ![7, 8, 9].contains(Self.type(nal)) {
            var length = UInt32(nal.count).bigEndian
            frame.append(Data(bytes: &length, count: 4))
            frame.append(nal)
        }
        return frame
    }
}

/// Reassembles RTP payloads into access units: single NAL units,
/// aggregation (STAP-A) and fragmentation (FU-A) packets. A frame that
/// loses a packet is dropped whole rather than decoded broken.
struct H264Depacketizer: Sendable {
    private var nalUnits: [Data] = []
    private var fragment: Data?
    private var timestamp: UInt32?
    private var lastSequence: UInt16?
    private var damaged = false

    /// The finished access unit, when `packet` completes one (its marker
    /// bit) or starts the next (a new timestamp).
    mutating func push(_ packet: RTPPacket) -> AccessUnit? {
        var finished: AccessUnit?
        if let timestamp, timestamp != packet.timestamp { finished = finish() }
        if let last = lastSequence, packet.sequence != last &+ 1 { damaged = true; fragment = nil }
        lastSequence = packet.sequence
        timestamp = packet.timestamp
        take(packet.payload)
        if packet.marker { finished = finish() ?? finished }
        return finished
    }

    private mutating func take(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard let header = bytes.first else { return }
        switch header & 0x1F {
        case 24:
            var offset = 1
            while offset + 2 <= bytes.count {
                let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + size <= bytes.count else { damaged = true; return }
                nalUnits.append(Data(bytes[offset..<offset + size]))
                offset += size
            }
        case 28:
            guard bytes.count >= 2 else { damaged = true; return }
            let start = bytes[1] & 0x80 != 0, end = bytes[1] & 0x40 != 0
            if start { fragment = Data([header & 0xE0 | bytes[1] & 0x1F]) }
            guard fragment != nil else { damaged = true; return }
            fragment!.append(contentsOf: bytes[2...])
            if end { nalUnits.append(fragment!); fragment = nil }
        default:
            nalUnits.append(payload)
        }
    }

    private mutating func finish() -> AccessUnit? {
        defer { nalUnits = []; fragment = nil; damaged = false }
        guard !damaged, fragment == nil, !nalUnits.isEmpty, let timestamp else { return nil }
        return AccessUnit(nalUnits: nalUnits, timestamp: timestamp)
    }
}

/// The RTCP the receiver sends back: a receiver report keeps the phone
/// streaming (it stops after ~25 s without one), and a picture-loss
/// indication asks it for a fresh keyframe.
struct RTCPReceiverReport: Equatable, Sendable {
    /// Our SSRC, as the negotiated stream configuration names it.
    let reporter: UInt32
    /// The phone's SSRC.
    let source: UInt32
    let highestSequence: UInt32

    var bytes: Data {
        var words: [UInt32] = [0x81C9_0007, reporter, source, 0, highestSequence, 0, 0, 0]
        for index in words.indices { words[index] = words[index].bigEndian }
        return words.withUnsafeBytes { Data($0) }
    }

    static func pictureLossIndication(reporter: UInt32, source: UInt32) -> Data {
        [0x81CE_0002, reporter, source].map(\.bigEndian).withUnsafeBytes { Data($0) }
    }
}

/// The Mac's end of the CoreDevice tunnel: its address on the phone's
/// network prefix (the phone is `…::1`, the Mac `…::2`).
enum TunnelAddress {
    static func local(facing phone: String, among addresses: [String]) -> String? {
        let prefix = Self.prefix(phone)
        return addresses.first { $0 != phone && Self.prefix($0) == prefix }
    }

    /// The first 64 bits, as written up to the third group.
    private static func prefix(_ address: String) -> [Substring] {
        Array(address.split(separator: ":", omittingEmptySubsequences: false).prefix(3))
    }
}
