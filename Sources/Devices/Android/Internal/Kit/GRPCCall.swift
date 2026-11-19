import Foundation

/// One call to the emulator's control API as HTTP/2 bytes (cleartext, prior
/// knowledge): a HEADERS frame of HPACK literals — never indexed, never
/// Huffman, so no table is kept — and its message, length-prefixed, in one
/// DATA frame that ends the stream. Each call is a stream of its own (odd
/// ids, rising) on one connection. Measured: docs/features/android/design.md.
struct GRPCCall: Sendable {
    /// HTTP/2's connection preface, then a 16 MB window — per stream in its
    /// SETTINGS, for the connection in a WINDOW_UPDATE — so a whole picture
    /// (10 MB of RGBA) arrives without waiting on 160 window updates.
    static let opening = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        + GRPCFrame.bytes(kind: 4, flags: 0, stream: 0, Data([0x00, 0x04, 0x01, 0x00, 0x00, 0x00]))
        + GRPCFrame.bytes(kind: 8, flags: 0, stream: 0, Data([0x00, 0xFF, 0x00, 0x00]))

    let bytes: Data

    init(method: String, stream: UInt32, authority: String, token: String, message: Data) {
        let headers = [(":method", "POST"), (":scheme", "http"),
                       (":path", "/android.emulation.control.EmulatorController/\(method)"),
                       (":authority", authority), ("content-type", "application/grpc"),
                       ("te", "trailers"), ("authorization", "Bearer \(token)")]
            .reduce(into: Data()) { $0 += Self.literal($1.0, $1.1) }
        var framed = Data([0])
        withUnsafeBytes(of: UInt32(message.count).bigEndian) { framed += $0 }
        framed += message
        bytes = GRPCFrame.bytes(kind: 1, flags: 0x04, stream: stream, headers)   // END_HEADERS
            + GRPCFrame.bytes(kind: 0, flags: 0x01, stream: stream, framed)      // END_STREAM
    }

    /// HPACK "literal header field without indexing — new name".
    private static func literal(_ name: String, _ value: String) -> Data {
        Data([0x00]) + length(name.utf8.count) + Data(name.utf8) + length(value.utf8.count) + Data(value.utf8)
    }

    /// An HPACK integer with a 7-bit prefix, no Huffman flag.
    private static func length(_ count: Int) -> Data {
        guard count >= 127 else { return Data([UInt8(count)]) }
        var rest = count - 127
        var out = Data([127])
        while rest >= 128 {
            out.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        out.append(UInt8(rest))
        return out
    }
}

/// The replies on one stream, read out of whatever bytes the connection
/// delivers: frames are cut out as they complete, the stream's DATA joined
/// and split into gRPC messages. What the connection owes the server back —
/// the window each DATA frame used, an ack of its settings — waits in
/// `takeAnswers()`.
struct GRPCReplies: Sendable {
    let stream: UInt32
    private var frames = Data()
    private var messages = Data()
    private var answers = Data()

    init(stream: UInt32) { self.stream = stream }

    /// The whole messages `bytes` completes on this stream.
    mutating func push(_ bytes: Data) -> [Data] {
        frames += bytes
        while frames.count >= 9 {
            let start = frames.startIndex
            let length = Int(frames[start]) << 16 | Int(frames[start + 1]) << 8 | Int(frames[start + 2])
            guard frames.count >= 9 + length else { break }
            let kind = frames[start + 3], flags = frames[start + 4]
            let id = frames[(start + 5)..<(start + 9)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF
            let payload = Data(frames[(start + 9)..<(start + 9 + length)])
            frames = Data(frames.dropFirst(9 + length))
            switch kind {
            case 0:
                if id == stream { messages += payload }
                if length > 0 {
                    var window = Data()
                    withUnsafeBytes(of: UInt32(length).bigEndian) { window += $0 }
                    answers += GRPCFrame.bytes(kind: 8, flags: 0, stream: 0, window)
                        + GRPCFrame.bytes(kind: 8, flags: 0, stream: id, window)
                }
            case 4 where flags & 0x01 == 0:
                answers += GRPCFrame.bytes(kind: 4, flags: 0x01, stream: 0, Data())
            default:
                break
            }
        }
        var whole: [Data] = []
        while messages.count >= 5 {
            let start = messages.startIndex
            let length = messages[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard messages.count >= 5 + length else { break }
            whole.append(Data(messages[(start + 5)..<(start + 5 + length)]))
            messages = Data(messages.dropFirst(5 + length))
        }
        return whole
    }

    /// The frames owed the server since last asked.
    mutating func takeAnswers() -> Data {
        defer { answers = Data() }
        return answers
    }
}

/// An HTTP/2 frame: a 24-bit length, its type, flags and stream id.
enum GRPCFrame {
    static func bytes(kind: UInt8, flags: UInt8, stream: UInt32, _ payload: Data) -> Data {
        var out = Data([UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF),
                        kind, flags])
        withUnsafeBytes(of: (stream & 0x7FFF_FFFF).bigEndian) { out += $0 }
        return out + payload
    }
}
