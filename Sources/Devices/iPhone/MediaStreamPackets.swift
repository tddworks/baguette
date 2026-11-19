import BaguetteDevice
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

/// The NAL units of one H.264 picture, as the phone encoded it.
struct AccessUnit: Equatable, Sendable {
    let nalUnits: [Data]
    let timestamp: UInt32

    /// A NAL unit's type, from its one-byte header.
    static func type(of nal: Data) -> UInt8 { (nal.first ?? 0) & 0x1F }

    /// A picture decodable on its own: it holds an IDR slice.
    var isKeyframe: Bool { nalUnits.contains { Self.type(of: $0) == 5 } }

    /// The SPS and PPS this unit carries, in decoder order — or none
    /// unless it carries both.
    var parameterSets: [Data] {
        let sets = [7, 8].compactMap { type in nalUnits.first { Self.type(of: $0) == type } }
        return sets.count == 2 ? sets : []
    }

    /// The picture's NAL units, each behind a four-byte length, leaving out
    /// parameter sets and delimiters — the frame a decoder configured from
    /// `parameterSets` takes.
    var lengthPrefixedFrame: Data {
        var frame = Data()
        for nal in nalUnits where ![7, 8, 9].contains(Self.type(of: nal)) {
            var length = UInt32(nal.count).bigEndian
            frame.append(Data(bytes: &length, count: 4))
            frame.append(nal)
        }
        return frame
    }
}

/// Reassembles H.264 RTP payloads (RFC 6184) into access units: single
/// NAL units, aggregation (STAP-A 24) and fragmentation (FU-A 28) packets,
/// plus the sample description the phone sends ahead of its pictures. A
/// frame that loses a packet is dropped whole rather than decoded broken.
struct VideoDepacketizer: Sendable {
    private var nalUnits: [Data] = []
    private var fragment: Data?
    private var timestamp: UInt32?
    private var lastSequence: UInt16?
    private var damaged = false
    /// The SPS and PPS from the phone's last sample description.
    private var configuration: [Data] = []
    /// Frames thrown away for a lost or broken packet, since the start.
    private(set) var droppedFrames = 0

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
        guard let first = bytes.first else { return }
        if first == 0x92 {
            configuration = Self.parameterSets(inSampleDescription: payload)
            return
        }
        switch first & 0x1F {
        case 24:
            aggregate(bytes, from: 1)
        case 28:
            guard bytes.count >= 2 else { damaged = true; return }
            fragmentPart(bytes, fuHeader: bytes[1], from: 2, header: [first & 0xE0 | bytes[1] & 0x1F])
        default:
            nalUnits.append(payload)
        }
    }

    private mutating func aggregate(_ bytes: [UInt8], from start: Int) {
        var offset = start
        while offset + 2 <= bytes.count {
            let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + size <= bytes.count else { damaged = true; return }
            nalUnits.append(Data(bytes[offset..<offset + size]))
            offset += size
        }
    }

    private mutating func fragmentPart(_ bytes: [UInt8], fuHeader: UInt8, from start: Int, header: [UInt8]) {
        if fuHeader & 0x80 != 0 { fragment = Data(header) }
        guard fragment != nil else { damaged = true; return }
        fragment!.append(contentsOf: bytes[start...])
        if fuHeader & 0x40 != 0 { nalUnits.append(fragment!); fragment = nil }
    }

    private mutating func finish() -> AccessUnit? {
        defer { nalUnits = []; fragment = nil; damaged = false }
        if damaged || fragment != nil { droppedFrames += 1; return nil }
        guard !nalUnits.isEmpty, let timestamp else { return nil }
        let unit = AccessUnit(nalUnits: nalUnits, timestamp: timestamp)
        guard unit.isKeyframe, unit.parameterSets.isEmpty, !configuration.isEmpty else { return unit }
        return AccessUnit(nalUnits: configuration + nalUnits, timestamp: timestamp)
    }

    /// The SPS and PPS of the avcC atom in the sample description an H.264
    /// stream sends ahead of its first picture (payload `0x92`, outside the
    /// NAL unit types), or none when there is no well-formed atom.
    private static func parameterSets(inSampleDescription payload: Data) -> [Data] {
        let bytes = [UInt8](payload)
        guard let tag = payload.range(of: Data("avcC".utf8)).map({ $0.lowerBound - payload.startIndex }),
              tag >= 4, bytes.count >= tag + 10 else { return [] }
        let end = min(bytes.count, tag - 4 + bytes[(tag - 4)..<tag].reduce(0) { $0 << 8 | Int($1) })
        var offset = tag + 4 + 5
        var sets: [Data] = []
        for countMask in [0x1F, 0xFF] {
            guard offset < end else { return [] }
            let count = Int(bytes[offset]) & countMask
            offset += 1
            for _ in 0..<count {
                guard offset + 2 <= end else { return [] }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + length <= end else { return [] }
                sets.append(Data(bytes[offset..<offset + length]))
                offset += length
            }
        }
        return sets
    }
}

/// Whether a frame may go to the decoder. A frame predicted from one the
/// decoder never saw paints stale blocks (a mosaic) until the next
/// keyframe — and a phone's stream sends keyframes only when asked — so
/// after any lost frame, nothing is decoded until a keyframe arrives, and
/// `needsKeyframe` says to ask for one. The last good picture stays up.
struct DecodeGate: Sendable {
    private(set) var needsKeyframe = true
    private var droppedSeen = 0

    /// - Parameter droppedSince: the depacketizer's running count of
    ///   dropped frames; a rise means a frame was lost since the last call.
    mutating func admits(_ unit: AccessUnit, droppedSince dropped: Int) -> Bool {
        if dropped != droppedSeen { droppedSeen = dropped; needsKeyframe = true }
        if unit.isKeyframe { needsKeyframe = false }
        return !needsKeyframe
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

    /// An RTCP APP packet acknowledging one whole picture, sent as each
    /// picture's last packet arrives.
    static func pictureReceived(reporter: UInt32, timestamp: UInt32) -> Data {
        [0x80CC_0003, reporter, 0x0000_0005, timestamp].map(\.bigEndian).withUnsafeBytes { Data($0) }
    }

    /// The `RCTL` APP packet a receiver sends every 50 ms: pictures received,
    /// a millisecond clock, and the highest sequence past the first. The
    /// phone's encoder steers its reference pictures by it; without it, fast
    /// motion leaves the picture smeared while decoding reports no error.
    static func receiverControl(reporter: UInt32, clock: UInt16, pictures: UInt16, packets: UInt16) -> Data {
        [0x80CC_0007, reporter, 0x5243_544C, 0x8500_0004,
         UInt32(pictures) << 16, 0, UInt32(clock) << 16, UInt32(packets) << 16]
            .map(\.bigEndian).withUnsafeBytes { Data($0) }
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
