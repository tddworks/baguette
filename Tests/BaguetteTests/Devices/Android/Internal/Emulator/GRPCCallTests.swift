import Foundation
import Testing
@testable import Baguette

/// One gRPC call as HTTP/2 bytes — the preface, its HEADERS (HPACK literals)
/// and its message — and the replies read back out of DATA frames.
@Suite("GRPCCall")
struct GRPCCallTests {
    /// HPACK "literal without indexing, new name": 0x00, then name and value,
    /// each a 7-bit length and the raw bytes.
    private static func literal(_ name: String, _ value: String) -> Data {
        Data([0x00, UInt8(name.utf8.count)]) + Data(name.utf8) + Data([UInt8(value.utf8.count)]) + Data(value.utf8)
    }

    @Test func `should open the connection with HTTP/2's preface and empty settings`() {
        #expect(GRPCCall.opening == Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8) + Data([0, 0, 0, 4, 0, 0, 0, 0, 0]))
    }

    @Test func `should name the call, its content type and the token in its headers`() {
        let call = GRPCCall(method: "sendTouch", stream: 1, authority: "localhost:8554", token: "tok", message: Data())

        let headers = Self.literal(":method", "POST") + Self.literal(":scheme", "http")
            + Self.literal(":path", "/android.emulation.control.EmulatorController/sendTouch")
            + Self.literal(":authority", "localhost:8554") + Self.literal("content-type", "application/grpc")
            + Self.literal("te", "trailers") + Self.literal("authorization", "Bearer tok")
        let frame = Data([0, 0, UInt8(headers.count), 1, 0x04, 0, 0, 0, 1]) + headers
        #expect(call.bytes.prefix(frame.count) == frame)
    }

    @Test func `should send the message length-prefixed in one DATA frame that ends the stream`() {
        let call = GRPCCall(method: "sendTouch", stream: 3, authority: "a", token: "t", message: Data([0xAA, 0xBB]))

        let data = Data([0, 0, 7, 0, 0x01, 0, 0, 0, 3, 0, 0, 0, 0, 2, 0xAA, 0xBB])
        #expect(call.bytes.suffix(data.count) == data)
    }

    @Test func `should read the replies a stream's DATA frames carry, split however they arrive`() {
        var replies = GRPCReplies(stream: 1)
        let message = Data([0, 0, 0, 0, 3, 7, 8, 9])
        let frame = Data([0, 0, UInt8(message.count), 0, 0, 0, 0, 0, 1]) + message
        let other = Data([0, 0, 1, 0, 0, 0, 0, 0, 5, 0xEE])

        let first = replies.push(other + frame.prefix(10))
        let second = replies.push(frame.dropFirst(10))

        #expect(first.isEmpty)
        #expect(second == [Data([7, 8, 9])])
    }

    @Test func `should give back the window each DATA frame used, so a long stream keeps flowing`() {
        var replies = GRPCReplies(stream: 1)
        let message = Data([0, 0, 0, 0, 1, 7])

        _ = replies.push(Data([0, 0, 6, 0, 0, 0, 0, 0, 1]) + message)

        let six = Data([0, 0, 0, 6])
        #expect(replies.takeAnswers() == Data([0, 0, 4, 8, 0, 0, 0, 0, 0]) + six + Data([0, 0, 4, 8, 0, 0, 0, 0, 1]) + six)
        #expect(replies.takeAnswers().isEmpty)
    }

    @Test func `should acknowledge the server's settings`() {
        var replies = GRPCReplies(stream: 1)

        _ = replies.push(Data([0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 100]))

        #expect(replies.takeAnswers() == Data([0, 0, 0, 4, 0x01, 0, 0, 0, 0]))
    }
}
