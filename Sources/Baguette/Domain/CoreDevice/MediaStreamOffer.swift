import BaguetteDevice
import Foundation

/// What this Mac offers a phone when it asks for the phone's screen: the
/// receiver it is (our SSRC), the one codec it takes, and the bitrates it
/// can stand — the `negotiatorOffer` of CoreDevice's media-stream start.
///
/// H.264 only. Offered HEVC too, the phone picks HEVC, and its HEVC
/// stream doesn't survive motion: every packet arrives, yet VideoToolbox
/// and ffmpeg alike decode a swipe into a mosaic that stays until the next
/// keyframe. Its H.264 stream decodes whole. The fields are the ones
/// AVConference's own negotiator writes (mode 5, video), with its HEVC
/// entry left out. Research: docs/features/real-devices/design.md.
struct MediaStreamOffer: Equatable, Sendable {
    /// The Mac the phone streams to, as the offer names it.
    struct Mac: Equatable, Sendable {
        let model: String
        let build: String
    }

    /// RTP payload type of the H.264 stream the phone answers with.
    static let payloadType: UInt8 = 123

    let receiver: UInt32
    let mac: Mac
    let callID: UUID
    /// When the offer was made, as an NTP timestamp.
    let made: UInt64

    init(receiver: UInt32, host mac: Mac, callID: UUID = UUID(), made: UInt64) {
        self.receiver = receiver
        self.mac = mac
        self.callID = callID
        self.made = made
    }

    /// The property list the phone reads.
    var bytes: Data {
        let plist: [String: Any] = [
            "avcMediaStreamNegotiatorMediaBlob": Self.zlib(media),
            "avcMediaStreamNegotiatorMode": 5,
            "avcMediaStreamOptionCallID": callID.uuidString,
            "avcMediaStreamOptionRemoteEndpointInfo": endpoint,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
    }

    /// The media description (protobuf): who receives, in which codec, at what bitrates.
    var media: Data {
        var codec = Protobuf()
        codec.number(1, UInt64(Self.payloadType))
        for direction: UInt64 in [1, 2, 1, 2] {
            codec.message(2) { $0.number(1, 1); $0.number(2, direction); $0.number(3, 50115); $0.number(4, 0) }
        }
        codec.string(3, "FLS;SW:1;")
        codec.number(4, 1)

        var receiver = Protobuf()
        receiver.number(1, UInt64(self.receiver))
        receiver.number(2, 0)
        receiver.message(3, codec)
        receiver.number(7, 1)
        receiver.number(8, 255)
        receiver.number(12, 1)

        var media = Protobuf()
        media.number(1, 1)
        media.number(2, 1)
        media.message(5, receiver)
        media.string(6, "Viceroy 1.7.0")
        media.number(8, 0)
        // Bitrate records (kind, bit/s, buffer); kind 0 with 6 Mbit/s is the cap the phone keeps to.
        let bitrates: [(UInt64, UInt64, UInt64?)] = [
            (4074, 0, 16384), (0, 20_000_000, 98304), (0, 40_000_000, 12288), (0, 60_000_000, 262_144),
            (16, 4100, nil), (0, 100_000_000, 1_048_576), (4, 6500, nil), (0, 6_000_000, 131_072),
            (1, 299, nil), (0, 75_000_000, 524_288),
        ]
        for (kind, rate, buffer) in bitrates {
            media.message(9) { record in
                record.number(1, kind)
                record.number(2, rate)
                if let buffer { record.number(3, buffer) }
            }
        }
        media.number(13, made)
        media.number(14, 2)
        media.number(16, 0)
        media.number(18, 1)
        return media.data
    }

    private var endpoint: Data {
        var endpoint = Protobuf()
        endpoint.number(1, 0)
        endpoint.number(2, 1)
        endpoint.string(3, mac.model)
        endpoint.string(4, "2235.63.5.2")
        endpoint.string(5, mac.build)
        return endpoint.data
    }

    /// zlib framing around Foundation's raw deflate: header, data, Adler-32.
    private static func zlib(_ data: Data) -> Data {
        let deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return Data([0x78, 0x9C]) + deflated + withUnsafeBytes(of: (b << 16 | a).bigEndian) { Data($0) }
    }
}

/// Just enough protobuf to write the offer: varints and length-delimited fields.
private struct Protobuf {
    private(set) var data = Data()

    mutating func number(_ field: UInt64, _ value: UInt64) {
        varint(field << 3)
        varint(value)
    }

    mutating func string(_ field: UInt64, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: UInt64, _ value: Protobuf) {
        bytes(field, value.data)
    }

    mutating func message(_ field: UInt64, _ build: (inout Protobuf) -> Void) {
        var value = Protobuf()
        build(&value)
        message(field, value)
    }

    private mutating func bytes(_ field: UInt64, _ value: Data) {
        varint(field << 3 | 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    private mutating func varint(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }
}
