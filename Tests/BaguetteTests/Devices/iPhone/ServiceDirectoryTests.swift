import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("ServiceDirectory")
struct ServiceDirectoryTests {
    @Test func `should find the phone's service directory port from remoted's connection to it`() {
        let nettop = """
            ,state,
            tcp6 fdd3:48cf:f69f::2.51508<->fdd3:48cf:f69f::1.55478,Established,
            tcp6 fd77::2.50001<->fd77::1.57198,Established,
            tcp4 127.0.0.1.8421<->127.0.0.1.60000,Established,
            """

        #expect(ServiceDirectory.port(fromNettop: nettop, phone: "fdd3:48cf:f69f::1") == 55478)
    }

    @Test func `should find no directory port while remoted holds no connection to the phone`() {
        let nettop = "tcp6 fdd3:48cf:f69f::2.51508<->fdd3:48cf:f69f::1.55478,Closed,\n"

        #expect(ServiceDirectory.port(fromNettop: nettop, phone: "fdd3:48cf:f69f::1") == nil)
        #expect(ServiceDirectory.port(fromNettop: "", phone: "fdd3:48cf:f69f::1") == nil)
    }

    @Test func `should match the phone's address however it is written`() {
        let nettop = "tcp6 fdd3:48cf:f69f:0::2.51508<->fdd3:48cf:f69f:0:0:0:0:1.55478,Established,\n"

        #expect(ServiceDirectory.port(fromNettop: nettop, phone: "fdd3:48cf:f69f::1") == 55478)
    }

    @Test func `should read each service's port from the directory's handshake`() {
        let handshake = XPCObject.dictionary([
            "MessageType": .string("Handshake"),
            "Properties": .dictionary(["UniqueDeviceID": .string("00008160-001239C43AA0000A")]),
            "Services": .dictionary([
                "com.apple.accessibility.axAuditDaemon.remoteAXService": .dictionary([
                    "Port": .string("61501"), "Entitlement": .string("AppleInternal"),
                ]),
                "com.apple.broken": .dictionary(["Port": .string("none")]),
            ]),
        ])

        #expect(ServiceDirectory(handshake: handshake)?.ports
            == ["com.apple.accessibility.axAuditDaemon.remoteAXService": 61501])
        #expect(ServiceDirectory(handshake: handshake)?.udid == "00008160-001239C43AA0000A")
    }

    @Test func `should read no directory from a message that isn't the handshake`() {
        #expect(ServiceDirectory(handshake: .dictionary(["MessageType": .string("Heartbeat")])) == nil)
        #expect(ServiceDirectory(handshake: .string("Handshake")) == nil)
    }
}

@Suite("XPCObject")
struct XPCObjectTests {
    @Test func `should read back every kind of value it writes`() throws {
        let value = XPCObject.dictionary([
            "string": .string("Handshake"), "bool": .bool(true), "int": .int64(-7), "uint": .uint64(61501),
            "double": .double(1.5), "data": .data(Data([1, 2, 3])), "null": .null,
            "uuid": .uuid(UUID(uuidString: "30546CC9-90DC-5F06-87D3-42D2C2E913D1")!),
            "array": .array([.string("a"), .uint64(2)]), "nested": .dictionary(["k": .string("v")]),
        ])

        var reader = XPCObject.Reader(value.bytes)
        #expect(try reader.object() == value)
    }

    @Test func `should lay a dictionary out as the XPC wire does, keys padded to four bytes`() {
        let bytes = XPCObject.dictionary(["Port": .string("61501")]).bytes

        #expect(bytes == Data([
            0x00, 0xF0, 0, 0,  0x1C, 0, 0, 0,  1, 0, 0, 0,     // dictionary, 28 bytes after this word, 1 entry
            0x50, 0x6F, 0x72, 0x74, 0, 0, 0, 0,                // "Port\0" padded
            0x00, 0x90, 0, 0,  6, 0, 0, 0,                     // string, 6 bytes with its NUL
            0x36, 0x31, 0x35, 0x30, 0x31, 0, 0, 0,             // "61501\0" padded
        ]))
    }

    @Test func `should refuse a string without its terminating NUL`() {
        var reader = XPCObject.Reader(Data([0x00, 0x90, 0, 0, 4, 0, 0, 0, 0x41, 0x42, 0x43, 0x44]))
        #expect(throws: XPCObject.Malformed(what: "string")) { try reader.object() }
    }

    @Test func `should read no string from a value that isn't one`() {
        #expect(XPCObject.uint64(5).string == nil)
        #expect(XPCObject.string("x")["key"] == nil)
    }

    @Test func `should refuse bytes that end inside a value`() {
        var reader = XPCObject.Reader(Data([0x00, 0x90, 0, 0, 9, 0, 0, 0, 0x41]))
        #expect(throws: XPCObject.Malformed.self) { try reader.object() }
    }
}

@Suite("XPCMessage")
struct XPCMessageTests {
    @Test func `should frame a message the way the wire reads it back`() throws {
        let message = XPCMessage(flags: 0x1, id: 7, body: .dictionary([:]))

        let read = try #require(try XPCMessage.read(from: message.bytes))

        #expect(read.message == message)
        #expect(read.length == message.bytes.count)
    }

    @Test func `should wait for the rest of a message that hasn't all arrived`() throws {
        let bytes = XPCMessage(flags: 0x1, id: 1, body: .string("Handshake")).bytes

        #expect(try XPCMessage.read(from: bytes.prefix(bytes.count - 1)) == nil)
    }

    @Test func `should refuse a message whose body isn't XPC's`() {
        var bytes = XPCMessage(flags: 0x1, id: 1, body: .string("Handshake")).bytes
        bytes[24] = 0

        #expect(throws: XPCObject.Malformed(what: "body header")) { try XPCMessage.read(from: bytes) }
    }

    @Test func `should carry no body when a message is only its header`() throws {
        let read = try #require(try XPCMessage.read(from: XPCMessage(flags: 0x201, id: 0, body: nil).bytes))

        #expect(read.message.body == nil)
        #expect(read.length == 24)
    }
}

@Suite("HTTP2Frame")
struct HTTP2FrameTests {
    @Test func `should read a frame's length, type, flags and stream from its header`() throws {
        let frame = HTTP2Frame(type: .data, flags: 0x1, stream: 3, payload: Data([1, 2, 3]))

        let header = try #require(HTTP2Frame.Header(frame.bytes.prefix(9)))

        #expect(header == HTTP2Frame.Header(length: 3, type: 0, flags: 0x1, stream: 3))
        #expect(frame.bytes.dropFirst(9) == Data([1, 2, 3]))
    }

    @Test func `should open RemoteXPC with the HTTP/2 preface, settings and its two streams`() throws {
        let opening = HTTP2Frame.remoteXPCOpening
        let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        var frames: [HTTP2Frame.Header] = []
        var rest = opening.dropFirst(preface.count)
        while let header = HTTP2Frame.Header(rest.prefix(9)) {
            frames.append(header)
            rest = rest.dropFirst(9 + header.length)
        }

        #expect(opening.prefix(preface.count) == preface)
        #expect(frames.map(\.type) == [4, 8, 1, 0, 1, 0, 0])       // settings, window, headers, data …
        #expect(frames.map(\.stream) == [0, 0, 1, 1, 3, 1, 3])
        #expect(rest.isEmpty)
    }
}
