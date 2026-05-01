import Testing
import Foundation
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

    // makeStream just dispatches to the right concrete type — both
    // constructors are pure (encoders/scalers allocate lazily, no IO
    // until `start()`), so a fake sink is enough.
    @Test func `makeStream returns MJPEGStream for mjpeg`() {
        let stream = StreamFormat.mjpeg.makeStream(
            config: .default, sink: FakeFrameSink(), quality: 0.7
        )
        #expect(stream is MJPEGStream)
        #expect(stream.config == .default)
    }

    @Test func `makeStream returns AVCCStream for avcc`() {
        let stream = StreamFormat.avcc.makeStream(
            config: .default, sink: FakeFrameSink(), quality: 0.7
        )
        #expect(stream is AVCCStream)
        #expect(stream.config == .default)
    }
}

private final class FakeFrameSink: FrameSink, @unchecked Sendable {
    func write(_ data: Data) {}
}
