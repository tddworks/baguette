import Testing
@testable import Baguette

@Suite("StreamFormat")
struct StreamFormatTests {

    @Test func `mjpeg parses from raw string`() {
        #expect(StreamFormat(rawValue: "mjpeg") == .mjpeg)
    }

    @Test func `avcc parses from raw string`() {
        #expect(StreamFormat(rawValue: "avcc") == .avcc)
    }

    @Test func `unknown raw string is nil`() {
        #expect(StreamFormat(rawValue: "h265") == nil)
    }

    @Test func `mjpeg skips unchanged frames; avcc doesn't`() {
        #expect(StreamFormat.mjpeg.skipsUnchangedFrames)
        #expect(!StreamFormat.avcc.skipsUnchangedFrames)
    }
}
