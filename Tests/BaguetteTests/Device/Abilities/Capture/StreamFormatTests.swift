import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("StreamFormat")
struct StreamFormatTests {

    @Test func `should recognise mjpeg as a stream format`() {
        #expect(StreamFormat(rawValue: "mjpeg") == .mjpeg)
    }

    @Test func `should recognise avcc as a stream format`() {
        #expect(StreamFormat(rawValue: "avcc") == .avcc)
    }

    @Test func `should recognise no stream format when the name is unknown`() {
        #expect(StreamFormat(rawValue: "h265") == nil)
    }

    @Test func `should skip unchanged frames for mjpeg but not for avcc`() {
        #expect(StreamFormat.mjpeg.skipsUnchangedFrames)
        #expect(!StreamFormat.avcc.skipsUnchangedFrames)
    }

    // makeStream just dispatches to the right concrete type — both
    // constructors are pure (encoders/scalers allocate lazily, no IO
    // until `start()`), so a fake sink is enough.
    @Test func `should build an MJPEG stream with the given settings for mjpeg`() {
        let stream = StreamFormat.mjpeg.makeStream(
            config: .default, sink: FakeFrameSink(), quality: 0.7
        )
        #expect(stream is MJPEGStream)
        #expect(stream.config == .default)
    }

    @Test func `should build an AVCC stream with the given settings for avcc`() {
        let stream = StreamFormat.avcc.makeStream(
            config: .default, sink: FakeFrameSink(), quality: 0.7
        )
        #expect(stream is AVCCStream)
        #expect(stream.config == .default)
    }
}

private final class FakeFrameSink: FrameSink, @unchecked Sendable {
    func fail(_ error: any Error) {}
    func write(_ data: Data) {}
}
