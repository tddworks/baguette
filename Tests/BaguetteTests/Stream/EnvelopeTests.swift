import Testing
import Foundation
@testable import Baguette

@Suite("MJPEGEnvelope")
struct MJPEGEnvelopeTests {

    @Test func `header announces multipart with frame boundary`() {
        let header = String(data: MJPEGEnvelope.header, encoding: .utf8)
        #expect(header == "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n")
    }

    @Test func `framed prefixes content-length and wraps with CRLF boundary`() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let wrapped = MJPEGEnvelope.framed(jpeg: jpeg)
        let asString = String(data: wrapped, encoding: .isoLatin1) ?? ""
        #expect(asString.hasPrefix("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\n"))
        #expect(asString.hasSuffix("\r\n"))
        #expect(wrapped.suffix(6).prefix(4) == jpeg)
    }

    @Test func `framed handles empty jpeg`() {
        let wrapped = MJPEGEnvelope.framed(jpeg: Data())
        let asString = String(data: wrapped, encoding: .isoLatin1) ?? ""
        #expect(asString == "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 0\r\n\r\n\r\n")
    }
}

@Suite("AVCCEnvelope")
struct AVCCEnvelopeTests {

    @Test func `tags are 0x01 description, 0x02 keyframe, 0x03 delta, 0x04 seed`() {
        #expect(AVCCEnvelope.descriptionTag == 0x01)
        #expect(AVCCEnvelope.keyframeTag == 0x02)
        #expect(AVCCEnvelope.deltaTag == 0x03)
        #expect(AVCCEnvelope.seedTag == 0x04)
    }

    @Test func `description prefixes 4-byte big-endian length and tag`() {
        let avcc = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let framed = AVCCEnvelope.description(avcc: avcc)
        // [00 00 00 05][01][DE AD BE EF] — total length includes the tag byte.
        #expect(framed.count == 4 + 1 + 4)
        #expect(framed.prefix(4) == Data([0x00, 0x00, 0x00, 0x05]))
        #expect(framed[4] == 0x01)
        #expect(framed.suffix(4) == avcc)
    }

    @Test func `seed prepends big-endian length and seed tag`() {
        let jpeg = Data([0xAA, 0xBB, 0xCC])
        let framed = AVCCEnvelope.seed(jpeg: jpeg)
        // [00 00 00 04][04][AA BB CC]
        #expect(framed.count == 4 + 1 + 3)
        #expect(framed.prefix(4) == Data([0x00, 0x00, 0x00, 0x04]))
        #expect(framed[4] == 0x04)
        #expect(framed.suffix(3) == jpeg)
    }

    @Test func `keyframe prepends big-endian length and keyframe tag`() {
        let nalus = Data([0x01, 0x02, 0x03])
        let framed = AVCCEnvelope.keyframe(avcc: nalus)
        #expect(framed.count == 4 + 1 + 3)
        #expect(framed[4] == 0x02)
    }

    @Test func `delta prepends big-endian length and delta tag`() {
        let nalus = Data([0x01, 0x02, 0x03])
        let framed = AVCCEnvelope.delta(avcc: nalus)
        #expect(framed[4] == 0x03)
    }

    @Test func `length encodes correctly above 255 bytes`() {
        let big = Data(repeating: 0xAB, count: 1000)
        let framed = AVCCEnvelope.delta(avcc: big)
        // length = 1 (tag) + 1000 = 1001 = 0x3E9
        #expect(framed.prefix(4) == Data([0x00, 0x00, 0x03, 0xE9]))
    }
}
