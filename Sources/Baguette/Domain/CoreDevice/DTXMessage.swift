import BaguetteDevice
import Foundation

/// One DTX message, the framing Xcode's device services speak (the phone's
/// accessibility service among them): a 32-byte header — split across
/// fragments when long — then a payload of auxiliary arguments and an
/// archived object. A method call carries its selector as that object and
/// its arguments, archived, in the auxiliary part. Pure; the socket is elsewhere.
struct DTXMessage: Equatable, Sendable {
    let id: UInt32
    /// 0 for a call the sender starts; 1 for the reply to one.
    let conversation: UInt32
    let channel: Int32
    let expectsReply: Bool
    /// 0 for an empty acknowledgement, 2 for a method call.
    let type: UInt32
    let auxiliary: Data
    let object: Data

    struct Malformed: Error, Equatable {
        let what: String
    }

    private static let magic: UInt32 = 0x1F3D_5B79
    private static let headerSize = 32

    /// A call of `selector` with one archived `argument`, on the control channel.
    static func call(_ selector: String, argument: NSObject, id: UInt32, expectsReply: Bool = false) throws -> DTXMessage {
        let object = try NSKeyedArchiver.archivedData(withRootObject: selector as NSString, requiringSecureCoding: true)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: argument, requiringSecureCoding: true)
        // Auxiliary: a header (0x1F0, then the length after it), then each
        // argument as (key type 10 = none, value type 2 = object, length, bytes).
        let auxiliary = word(UInt64(0x1F0)) + word(UInt64(12 + archive.count))
            + word(UInt32(10)) + word(UInt32(2)) + word(UInt32(archive.count)) + archive
        return DTXMessage(id: id, conversation: 0, channel: 0, expectsReply: expectsReply,
                          type: 2, auxiliary: auxiliary, object: object)
    }

    /// The empty reply that tells the sender this message arrived.
    var acknowledgement: DTXMessage {
        DTXMessage(id: id, conversation: 1, channel: channel, expectsReply: false,
                   type: 0, auxiliary: Data(), object: Data())
    }

    /// The method a call names.
    var selector: String? {
        guard type == 2, !object.isEmpty else { return nil }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: object)) as String?
    }

    /// The call's first argument, unarchived as `T`.
    func argument<T: NSObject & NSSecureCoding>(of _: T.Type) throws -> T {
        let bytes = [UInt8](auxiliary)
        guard bytes.count >= 28 else { throw Malformed(what: "argument header") }
        let length = Int(Self.read(UInt32.self, bytes, at: 24))
        guard length <= bytes.count - 28,
              let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: T.self, from: Data(bytes[28..<28 + length]))
        else { throw Malformed(what: "argument") }
        return value
    }

    var bytes: Data {
        var data = Data()
        data += Self.word(Self.magic)
        data += Self.word(UInt32(Self.headerSize))
        data += Self.word(UInt16(0))
        data += Self.word(UInt16(1))
        data += Self.word(UInt32(16 + auxiliary.count + object.count))
        data += Self.word(id)
        data += Self.word(conversation)
        data += Self.word(channel)
        data += Self.word(UInt32(expectsReply ? 1 : 0))
        data += Self.word(type)
        data += Self.word(UInt32(auxiliary.count))
        data += Self.word(UInt64(auxiliary.count + object.count))
        return data + auxiliary + object
    }

    /// The next message off a stream, `next(n)` handing over exactly n bytes.
    /// A long message's first fragment declares the whole size and carries
    /// nothing; the fragments after it carry the body in order.
    static func read(_ next: (Int) throws -> Data) throws -> DTXMessage {
        let first = try header(next)
        guard first.index == 0 else { throw Malformed(what: "first fragment") }
        var body = Data()
        if first.count == 1 {
            body = try next(first.length)
        } else {
            for index in 1..<first.count {
                let fragment = try header(next)
                guard fragment.index == index, fragment.id == first.id,
                      fragment.length <= first.length - body.count else { throw Malformed(what: "fragment") }
                body += try next(fragment.length)
            }
        }
        let payload = [UInt8](body)
        guard payload.count == first.length, payload.count >= 16 else { throw Malformed(what: "payload size") }
        let type = read(UInt32.self, payload, at: 0)
        let auxiliarySize = Int(read(UInt32.self, payload, at: 4))
        guard read(UInt64.self, payload, at: 8) == UInt64(payload.count - 16), auxiliarySize <= payload.count - 16,
              type == 0 || type == 2 else { throw Malformed(what: "payload header") }
        return DTXMessage(id: first.id, conversation: first.conversation, channel: first.channel,
                          expectsReply: first.expectsReply, type: type,
                          auxiliary: Data(payload[16..<16 + auxiliarySize]), object: Data(payload[(16 + auxiliarySize)...]))
    }

    private struct Header {
        let index: Int, count: Int, length: Int
        let id: UInt32, conversation: UInt32, channel: Int32, expectsReply: Bool
    }

    private static func header(_ next: (Int) throws -> Data) throws -> Header {
        let bytes = [UInt8](try next(headerSize))
        guard bytes.count == headerSize, read(UInt32.self, bytes, at: 0) == magic,
              read(UInt32.self, bytes, at: 4) == UInt32(headerSize) else { throw Malformed(what: "header") }
        let index = Int(read(UInt16.self, bytes, at: 8)), count = Int(read(UInt16.self, bytes, at: 10))
        let length = Int(read(UInt32.self, bytes, at: 12))
        guard (1...512).contains(count), index < count, length <= 64 * 1024 * 1024 else { throw Malformed(what: "fragment fields") }
        return Header(index: index, count: count, length: length,
                      id: read(UInt32.self, bytes, at: 16), conversation: read(UInt32.self, bytes, at: 20),
                      channel: read(Int32.self, bytes, at: 24), expectsReply: read(UInt32.self, bytes, at: 28) == 1)
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, _ bytes: [UInt8], at offset: Int) -> T {
        bytes[offset..<offset + MemoryLayout<T>.size].reversed().reduce(T(0)) { $0 << 8 | T($1) }
    }

    private static func word<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
