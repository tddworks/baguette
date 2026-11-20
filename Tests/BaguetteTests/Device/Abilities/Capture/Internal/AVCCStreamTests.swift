import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import BaguetteDevice

/// What the AVCC stream sends, with VideoToolbox's compression session
/// mocked: a JPEG seed to paint at once, the avcC record, then keyframes
/// and deltas in order — and nothing once a frame fails or goes stale.
@Suite("AVCCStream")
struct AVCCStreamTests {

    private let sps = Data([0x67, 0x64, 0x00, 0x1F])
    private let pps = Data([0x68, 0xEE])

    private func screen() -> MockScreen {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willReturn()
        given(screen).stop().willReturn()
        return screen
    }

    /// A compression session that answers each frame with the next of
    /// `answers` (the last one repeats); one that `holds` keeps the answer
    /// back until the test lets it go.
    private func session(_ answers: [CompressionResult], holding held: Held? = nil) -> MockCompressionSession {
        let session = MockCompressionSession()
        let next = Counter()
        given(session).open(width: .any, height: .any, lowLatencyRateControl: .any).willReturn(0)
        given(session).set(.any).willReturn(0)
        given(session).prepare().willReturn(0)
        given(session).close().willReturn()
        given(session).submit(.any, at: .any, keyframe: .any, done: .any).willProduce { _, _, _, done in
            let answer = answers[min(next.increment(), answers.count - 1)]
            if let held { held.keep { done(answer) } } else { done(answer) }
            return 0
        }
        return session
    }

    private var keyframe: CompressionResult {
        CompressionResult(status: 0, dropped: false, frame: CompressedFrame(avcc: Data([0, 0, 0, 1, 0x65]), keyframe: true, sps: sps, pps: pps))
    }

    private var delta: CompressionResult {
        CompressionResult(status: 0, dropped: false, frame: CompressedFrame(avcc: Data([0, 0, 0, 1, 0x41]), keyframe: false, sps: nil, pps: nil))
    }

    private func stream(_ session: MockCompressionSession, sink: RecordingSink) -> AVCCStream {
        AVCCStream(config: .default, sink: sink, quality: 0.7,
                   encoder: H264Encoder(fps: 60, tuning: .strict, session: session))
    }

    /// Hand the stream one screen, and wait for what it makes of it.
    private func send(_ surface: IOSurface, to stream: AVCCStream) {
        stream.queue.sync { stream.encode(surface) }
        stream.queue.sync {}
    }

    private func tags(_ sink: RecordingSink) -> [UInt8] {
        sink.writes.compactMap { AVCCEnvelope.unwrap($0)?.tag }
    }

    @Test func `should paint a JPEG seed, then the avcC record, before the first keyframe`() throws {
        let sink = RecordingSink()
        let stream = stream(session([keyframe]), sink: sink)
        try stream.start(on: screen())

        send(Surfaces.filled(0x10), to: stream)

        #expect(tags(sink) == [AVCCEnvelope.seedTag, AVCCEnvelope.descriptionTag, AVCCEnvelope.keyframeTag])
        #expect(AVCCEnvelope.unwrap(sink.writes[1])?.payload == AVCDecoderConfigurationRecord.bytes(sps: sps, pps: pps))
        stream.stop()
    }

    @Test func `should send the frames after a keyframe as deltas`() throws {
        let sink = RecordingSink()
        let stream = stream(session([keyframe, delta]), sink: sink)
        try stream.start(on: screen())

        send(Surfaces.filled(0x10), to: stream)
        send(Surfaces.filled(0x20), to: stream)

        #expect(tags(sink).last == AVCCEnvelope.deltaTag)
        #expect(AVCCEnvelope.unwrap(sink.writes.last!)?.payload == Data([0, 0, 0, 1, 0x41]))
        stream.stop()
    }

    @Test func `should ask for a keyframe on the first frame and when a viewer asks for one`() throws {
        let session = session([keyframe])
        let stream = stream(session, sink: RecordingSink())
        try stream.start(on: screen())

        send(Surfaces.filled(0x10), to: stream)
        send(Surfaces.filled(0x20), to: stream)
        stream.requestKeyframe()
        send(Surfaces.filled(0x30), to: stream)

        verify(session).submit(.any, at: .any, keyframe: .value(true), done: .any).called(2)
        verify(session).submit(.any, at: .any, keyframe: .value(false), done: .any).called(1)
        stream.stop()
    }

    @Test func `should paint another seed when a viewer asks for one`() throws {
        let sink = RecordingSink()
        let stream = stream(session([keyframe, delta]), sink: sink)
        try stream.start(on: screen())

        send(Surfaces.filled(0x10), to: stream)
        stream.requestSnapshot()
        send(Surfaces.filled(0x20), to: stream)

        #expect(tags(sink).filter { $0 == AVCCEnvelope.seedTag }.count == 2)
        stream.stop()
    }

    @Test func `should end the stream when the encoder fails a frame`() throws {
        let sink = RecordingSink()
        let failed = CompressionResult(status: -12902, dropped: false, frame: nil)
        let stream = stream(session([failed, keyframe]), sink: sink)
        try stream.start(on: screen())

        send(Surfaces.filled(0x10), to: stream)
        send(Surfaces.filled(0x20), to: stream)

        #expect(sink.failures == 1)
        #expect(tags(sink) == [AVCCEnvelope.seedTag])
        stream.stop()
    }

    @Test func `should drop a frame encoded at the old scale`() throws {
        let sink = RecordingSink()
        let held = Held()
        let stream = stream(session([keyframe], holding: held), sink: sink)
        try stream.start(on: screen())
        stream.queue.sync { stream.encode(Surfaces.filled(0x10)) }

        try stream.apply(StreamConfig.default.with(scale: 2))
        held.release()
        stream.queue.sync {}

        #expect(tags(sink) == [AVCCEnvelope.seedTag])
        stream.stop()
    }

    @Test func `should start again from a seed and a keyframe when the scale changes`() throws {
        let sink = RecordingSink()
        let session = session([keyframe, delta])
        let stream = stream(session, sink: sink)
        try stream.start(on: screen())
        send(Surfaces.filled(0x10), to: stream)
        send(Surfaces.filled(0x20), to: stream)

        try stream.apply(StreamConfig.default.with(scale: 2))
        send(Surfaces.filled(0x30, width: 16, height: 16), to: stream)

        #expect(tags(sink).filter { $0 == AVCCEnvelope.seedTag }.count == 2)
        verify(session).submit(.any, at: .any, keyframe: .value(true), done: .any).called(2)
        stream.stop()
    }

    @Test func `should retune the encoder when the frame rate or bitrate changes`() throws {
        let session = session([keyframe])
        let stream = stream(session, sink: RecordingSink())
        try stream.start(on: screen())
        send(Surfaces.filled(0x10), to: stream)

        try stream.apply(StreamConfig.default.with(fps: 30, bitrateBps: 4_000_000))

        verify(session).set(.value(.expectedFrameRate(30))).called(1)
        verify(session).set(.value(.averageBitRate(4_000_000))).called(1)
        #expect(stream.config.fps == 30 && stream.config.bitrateBps == 4_000_000)
        stream.stop()
    }

    @Test func `should keep every change when its frame rate and bitrate are changed at once`() throws {
        let session = session([keyframe])
        // Retuning the encoder takes a moment, as VideoToolbox does.
        given(session).set(.any).willProduce { _ in usleep(200); return 0 }
        let stream = stream(session, sink: RecordingSink())
        try stream.start(on: screen())
        send(Surfaces.filled(0x10), to: stream)

        // One caller walks the frame rate up, the other the bitrate, together.
        DispatchQueue.concurrentPerform(iterations: 2) { caller in
            for step in 1...200 { try! stream.update(caller == 0 ? .fps(step) : .bitrate(step * 10_000)) }
        }

        #expect(stream.config.fps == 200 && stream.config.bitrateBps == 2_000_000)
        stream.stop()
    }

    @Test func `should send nothing once stopped`() throws {
        let sink = RecordingSink()
        let screen = screen()
        let session = session([keyframe])
        let stream = stream(session, sink: sink)
        try stream.start(on: screen)
        send(Surfaces.filled(0x10), to: stream)

        stream.stop()
        send(Surfaces.filled(0x20), to: stream)

        #expect(tags(sink).count == 3)
        verify(screen).stop().called(1)
        verify(session).close().called(1)
    }

    @Test func `should let go of the screen when it cannot start`() {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willThrow(ScreenDown())
        given(screen).stop().willReturn()
        let stream = stream(session([keyframe]), sink: RecordingSink())

        #expect(throws: ScreenDown.self) { try stream.start(on: screen) }
        verify(screen).stop().called(1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// The count before this call.
    func increment() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

/// An encoder answer kept back until the test lets it go.
final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [@Sendable () -> Void] = []
    func keep(_ answer: @escaping @Sendable () -> Void) { lock.withLock { answers.append(answer) } }
    func release() { lock.withLock { answers }.forEach { $0() } }
}
