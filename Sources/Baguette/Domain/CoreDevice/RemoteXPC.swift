import BaguetteDevice
import Foundation

// RemoteXPC: the XPC values a phone's services exchange over the CoreDevice
// tunnel, carried in HTTP/2 DATA frames. Pure values; the socket is
// elsewhere. Research: docs/features/real-devices/design.md.

/// One XPC value as the wire carries it: little-endian, every field padded
/// to four bytes, collections prefixed by their byte length and count.
enum XPCObject: Equatable, Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case date(Int64)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([XPCObject])
    case dictionary([String: XPCObject])

    struct Malformed: Error, Equatable {
        let what: String
    }

    private enum Tag: UInt32 {
        case null = 0x1000, bool = 0x2000, int64 = 0x3000, uint64 = 0x4000, double = 0x5000
        case date = 0x7000, data = 0x8000, string = 0x9000, uuid = 0xA000
        case array = 0xE000, dictionary = 0xF000
    }

    subscript(key: String) -> XPCObject? {
        if case let .dictionary(values) = self { return values[key] }
        return nil
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The value's wire bytes.
    var bytes: Data {
        var writer = Writer()
        writer.write(self)
        return writer.bytes
    }

    private struct Writer {
        var bytes = Data()

        mutating func word<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func padded(_ data: Data) {
            bytes.append(data)
            bytes.append(contentsOf: repeatElement(0, count: (4 - data.count % 4) % 4))
        }

        mutating func write(_ value: XPCObject) {
            switch value {
            case .null: word(Tag.null.rawValue)
            case let .bool(flag): word(Tag.bool.rawValue); word(UInt32(flag ? 1 : 0))
            case let .int64(number): word(Tag.int64.rawValue); word(number)
            case let .uint64(number): word(Tag.uint64.rawValue); word(number)
            case let .double(number): word(Tag.double.rawValue); word(number.bitPattern)
            case let .date(nanoseconds): word(Tag.date.rawValue); word(nanoseconds)
            case let .data(data): word(Tag.data.rawValue); word(UInt32(data.count)); padded(data)
            case let .string(text):
                let utf8 = Data(text.utf8) + [0]
                word(Tag.string.rawValue); word(UInt32(utf8.count)); padded(utf8)
            case let .uuid(uuid): word(Tag.uuid.rawValue); withUnsafeBytes(of: uuid.uuid) { bytes.append(contentsOf: $0) }
            case let .array(values):
                collection(.array, count: values.count) { writer in values.forEach { writer.write($0) } }
            case let .dictionary(values):
                collection(.dictionary, count: values.count) { writer in
                    for (key, child) in values.sorted(by: { $0.key < $1.key }) {
                        writer.padded(Data(key.utf8) + [0])
                        writer.write(child)
                    }
                }
            }
        }

        private mutating func collection(_ tag: Tag, count: Int, _ body: (inout Writer) -> Void) {
            word(tag.rawValue)
            let lengthAt = bytes.count
            word(UInt32(0))
            word(UInt32(count))
            body(&self)
            let length = UInt32(bytes.count - lengthAt - 4).littleEndian
            withUnsafeBytes(of: length) { bytes.replaceSubrange(lengthAt..<lengthAt + 4, with: $0) }
        }
    }

    /// Reads values off wire bytes, refusing any that run past the end.
    struct Reader {
        private let bytes: [UInt8]
        private(set) var position = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func object(depth: Int = 0) throws -> XPCObject {
            guard depth < 64 else { throw Malformed(what: "nesting") }
            guard let tag = Tag(rawValue: try word(UInt32.self)) else { throw Malformed(what: "type") }
            switch tag {
            case .null: return .null
            case .bool: return .bool(try word(UInt32.self) != 0)
            case .int64: return .int64(try word(Int64.self))
            case .uint64: return .uint64(try word(UInt64.self))
            case .double: return .double(Double(bitPattern: try word(UInt64.self)))
            case .date: return .date(try word(Int64.self))
            case .data: return .data(Data(try padded(Int(try word(UInt32.self)))))
            case .string:
                let raw = try padded(Int(try word(UInt32.self)))
                guard raw.last == 0, let text = String(bytes: raw.dropLast(), encoding: .utf8) else {
                    throw Malformed(what: "string")
                }
                return .string(text)
            case .uuid:
                let raw = Array(try take(16))
                return .uuid(UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                         raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])))
            case .array:
                _ = try word(UInt32.self)
                let count = Int(try word(UInt32.self))
                return .array(try (0..<count).map { _ in try object(depth: depth + 1) })
            case .dictionary:
                _ = try word(UInt32.self)
                let count = Int(try word(UInt32.self))
                var values: [String: XPCObject] = [:]
                for _ in 0..<count {
                    guard let end = bytes[position...].firstIndex(of: 0),
                          let key = String(bytes: bytes[position..<end], encoding: .utf8)
                    else { throw Malformed(what: "key") }
                    _ = try padded(end - position + 1)
                    values[key] = try object(depth: depth + 1)
                }
                return .dictionary(values)
            }
        }

        mutating func word<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).reversed().reduce(T(0)) { $0 << 8 | T($1) }
        }

        private mutating func padded(_ count: Int) throws -> ArraySlice<UInt8> {
            let value = try take(count)
            _ = try take((4 - count % 4) % 4)
            return value
        }

        private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - position else { throw Malformed(what: "length") }
            defer { position += count }
            return bytes[position..<position + count]
        }
    }
}

/// One RemoteXPC message: a 24-byte wrapper (magic, flags, body length, id)
/// around an optional body (its own magic and version, then one value).
struct XPCMessage: Equatable, Sendable {
    let flags: UInt32
    let id: UInt64
    let body: XPCObject?

    private static let magic: UInt32 = 0x29B0_0B92
    private static let bodyMagic: UInt32 = 0x4213_3742
    private static let version: UInt32 = 5

    var bytes: Data {
        var body = Data()
        if let value = self.body {
            body = Self.words([Self.bodyMagic, Self.version]) + value.bytes
        }
        return Self.words([Self.magic, flags]) + Self.word(UInt64(body.count)) + Self.word(id) + body
    }

    /// The first whole message in `bytes` and its length, or nil while it
    /// hasn't all arrived.
    static func read(from bytes: Data) throws -> (message: XPCMessage, length: Int)? {
        guard bytes.count >= 24 else { return nil }
        var reader = XPCObject.Reader(bytes)
        guard try reader.word(UInt32.self) == magic else { throw XPCObject.Malformed(what: "message magic") }
        let flags = try reader.word(UInt32.self)
        let size = try reader.word(UInt64.self)
        guard size <= 64 * 1024 * 1024 else { throw XPCObject.Malformed(what: "message size") }
        let id = try reader.word(UInt64.self)
        let length = 24 + Int(size)
        guard bytes.count >= length else { return nil }
        guard size > 0 else { return (XPCMessage(flags: flags, id: id, body: nil), length) }
        var body = XPCObject.Reader(Data(bytes.prefix(length).dropFirst(24)))
        guard try body.word(UInt32.self) == bodyMagic, try body.word(UInt32.self) == version else {
            throw XPCObject.Malformed(what: "body header")
        }
        return (XPCMessage(flags: flags, id: id, body: try body.object()), length)
    }

    private static func words(_ values: [UInt32]) -> Data { values.reduce(Data()) { $0 + word($1) } }
    private static func word<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// The phone's service directory: which port each of its services listens
/// on over the tunnel, as its handshake lists them.
struct ServiceDirectory: Equatable, Sendable {
    let udid: String?
    let ports: [String: UInt16]

    init?(handshake: XPCObject) {
        guard handshake["MessageType"]?.string == "Handshake",
              case let .dictionary(services)? = handshake["Services"] else { return nil }
        udid = handshake["Properties"]?["UniqueDeviceID"]?.string
        ports = services.compactMapValues { $0["Port"]?.string.flatMap(UInt16.init) }
    }

    /// The directory's own port: the one `remoted` holds a connection to on
    /// the phone's tunnel address, as `nettop -m tcp -n -x -p remoted -J state`
    /// lists it (`tcp6 <mac>.<port><-><phone>.<port>,Established,`).
    static func port(fromNettop listing: String, phone: String) -> UInt16? {
        let ports = Set(listing.split(whereSeparator: \.isNewline).compactMap { line -> UInt16? in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 1, fields[1] == "Established", fields[0].hasPrefix("tcp6 "),
                  let arrow = fields[0].range(of: "<->") else { return nil }
            let remote = fields[0][arrow.upperBound...]
            guard let dot = remote.lastIndex(of: "."),
                  let port = UInt16(remote[remote.index(after: dot)...]),
                  sameAddress(String(remote[..<dot]), phone) else { return nil }
            return port
        })
        return ports.count == 1 ? ports.first : nil
    }

    private static func sameAddress(_ a: String, _ b: String) -> Bool {
        var x = in6_addr(), y = in6_addr()
        let bare = { (address: String) in String(address.split(separator: "%").first ?? "") }
        guard inet_pton(AF_INET6, bare(a), &x) == 1, inet_pton(AF_INET6, bare(b), &y) == 1 else { return false }
        return withUnsafeBytes(of: &x) { left in withUnsafeBytes(of: &y) { right in left.elementsEqual(right) } }
    }
}

/// One HTTP/2 frame, as RemoteXPC carries its messages: a 9-byte header
/// (24-bit length, type, flags, 31-bit stream), then the payload.
struct HTTP2Frame: Equatable, Sendable {
    enum Kind: UInt8 { case data = 0, headers = 1, settings = 4, ping = 6, goAway = 7, windowUpdate = 8 }

    struct Header: Equatable, Sendable {
        let length: Int
        let type: UInt8
        let flags: UInt8
        let stream: UInt32

        init(length: Int, type: UInt8, flags: UInt8, stream: UInt32) {
            self.length = length
            self.type = type
            self.flags = flags
            self.stream = stream
        }

        /// Nil unless `bytes` is a whole 9-byte header.
        init?(_ bytes: Data) {
            let b = [UInt8](bytes)
            guard b.count == 9 else { return nil }
            length = Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2])
            type = b[3]
            flags = b[4]
            stream = (UInt32(b[5]) << 24 | UInt32(b[6]) << 16 | UInt32(b[7]) << 8 | UInt32(b[8])) & 0x7FFF_FFFF
        }
    }

    let type: Kind
    var flags: UInt8 = 0
    var stream: UInt32 = 0
    var payload = Data()

    var bytes: Data {
        let length = UInt32(payload.count)
        let header: [UInt8] = [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
                               type.rawValue, flags,
                               UInt8(stream >> 24 & 0x7F), UInt8(stream >> 16 & 0xFF), UInt8(stream >> 8 & 0xFF), UInt8(stream & 0xFF)]
        return Data(header) + payload
    }

    /// What a client sends to open RemoteXPC: the HTTP/2 preface and
    /// settings (100 streams, a 16 MiB window), then stream 1 (its first,
    /// empty message) and stream 3 (the reply stream).
    static var remoteXPCOpening: Data {
        let window: UInt32 = 16 * 1024 * 1024
        var settings = Data([0, 3]) + bigEndian(UInt32(100))
        settings += Data([0, 4]) + bigEndian(window)
        var opening = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        opening += HTTP2Frame(type: .settings, payload: settings).bytes
        opening += HTTP2Frame(type: .windowUpdate, payload: bigEndian(window - 65_535)).bytes
        opening += HTTP2Frame(type: .headers, flags: 0x4, stream: 1).bytes
        opening += HTTP2Frame(type: .data, stream: 1, payload: XPCMessage(flags: 0x1, id: 0, body: .dictionary([:])).bytes).bytes
        opening += HTTP2Frame(type: .headers, flags: 0x4, stream: 3).bytes
        opening += HTTP2Frame(type: .data, stream: 1, payload: XPCMessage(flags: 0x201, id: 0, body: nil).bytes).bytes
        opening += HTTP2Frame(type: .data, stream: 3, payload: XPCMessage(flags: 0x40_0001, id: 0, body: nil).bytes).bytes
        return opening
    }

    private static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
