import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

@Suite("DTXMessage")
struct DTXMessageTests {
    /// Reads `bytes` the way a socket hands them over, a few at a time.
    private func reading(_ bytes: Data) -> (Int) throws -> Data {
        var rest = bytes
        return { count in
            guard rest.count >= count else { throw DTXMessage.Malformed(what: "end of stream") }
            defer { rest = rest.dropFirst(count) }
            return Data(rest.prefix(count))
        }
    }

    @Test func `should call a method on the phone with its selector and argument`() throws {
        let call = try DTXMessage.call("clientNeedsAccessibility:", argument: NSNumber(value: true), id: 2)

        let read = try DTXMessage.read(reading(call.bytes))

        #expect(read.id == 2)
        #expect(read.selector == "clientNeedsAccessibility:")
        #expect(try read.argument(of: NSNumber.self) == NSNumber(value: true))
        #expect(!read.expectsReply)
    }

    @Test func `should begin every message with the DTX magic and a 32-byte header`() throws {
        let bytes = try DTXMessage.call("hostAPIVersion", argument: NSNumber(value: 1), id: 9).bytes

        #expect(bytes.prefix(8) == Data([0x79, 0x5B, 0x3D, 0x1F, 32, 0, 0, 0]))
    }

    @Test func `should rebuild a message the phone sent in fragments`() throws {
        let whole = try DTXMessage.call("processDataFromRemoteDevice:", argument: Data(repeating: 7, count: 300) as NSData, id: 3)
        let body = whole.bytes.dropFirst(32)
        let split = body.count / 2
        let fragments = Self.header(index: 0, count: 3, length: body.count, id: 3)
            + Self.header(index: 1, count: 3, length: split, id: 3) + body.prefix(split)
            + Self.header(index: 2, count: 3, length: body.count - split, id: 3) + body.dropFirst(split)

        let read = try DTXMessage.read(reading(Data(fragments)))

        #expect(read.selector == "processDataFromRemoteDevice:")
        #expect(try read.argument(of: NSData.self) == Data(repeating: 7, count: 300) as NSData)
    }

    @Test func `should acknowledge a message on its own channel and id, as the reply conversation`() throws {
        let call = try DTXMessage.call("_notifyOfPublishedCapabilities:", argument: NSDictionary(), id: 5, expectsReply: true)

        let ack = try DTXMessage.read(reading(call.acknowledgement.bytes))

        #expect(ack.id == 5)
        #expect(ack.conversation == 1)
        #expect(ack.selector == nil)
    }

    @Test func `should refuse bytes that aren't a DTX message`() {
        #expect(throws: DTXMessage.Malformed.self) {
            try DTXMessage.read(reading(Data(repeating: 0, count: 64)))
        }
    }

    private static func header(index: UInt16, count: UInt16, length: Int, id: UInt32) -> Data {
        var bytes = Data()
        func word<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        word(UInt32(0x1F3D_5B79)); word(UInt32(32)); word(index); word(count); word(UInt32(length))
        word(id); word(UInt32(0)); word(Int32(0)); word(UInt32(0))
        return bytes
    }
}
