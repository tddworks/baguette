import CoreMedia
import CoreVideo
import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

/// What the H.264 encoder decides, with VideoToolbox's compression session
/// mocked: when a session opens, which frames are keyframes, which tuning
/// it insists on, and which of the session's answers become a frame.
@Suite("H264Encoder")
struct H264EncoderTests {

    private let refused: Int32 = -12902

    private func frame(width: Int = 4, height: Int = 2) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    /// A session that opens, takes every property but `refusing`, and
    /// answers each frame with `answer`.
    private func session(
        answer: CompressionResult = CompressionResult(status: 0, dropped: false, frame: nil),
        refusing: CompressionProperty? = nil
    ) -> MockCompressionSession {
        let session = MockCompressionSession()
        let refused = refused
        given(session).open(width: .any, height: .any, lowLatencyRateControl: .any).willReturn(0)
        given(session).set(.any).willProduce { $0 == refusing ? refused : 0 }
        given(session).prepare().willReturn(0)
        given(session).close().willReturn()
        given(session).submit(.any, at: .any, keyframe: .any, done: .any).willProduce { _, _, _, done in
            done(answer)
            return 0
        }
        return session
    }

    @Test func `should open a session at the size of the first frame`() {
        let session = session()
        let encoder = H264Encoder(fps: 30, tuning: .lowLatency, session: session)

        encoder.encode(frame(width: 4, height: 2))

        verify(session).open(width: .value(4), height: .value(2), lowLatencyRateControl: .value(true)).called(1)
    }

    @Test func `should open a new session when the frame size changes`() {
        let session = session()
        let encoder = H264Encoder(fps: 30, session: session)

        encoder.encode(frame(width: 4, height: 2))
        encoder.encode(frame(width: 4, height: 2))
        encoder.encode(frame(width: 8, height: 4))

        verify(session).open(width: .any, height: .any, lowLatencyRateControl: .any).called(2)
        verify(session).open(width: .value(8), height: .value(4), lowLatencyRateControl: .any).called(1)
    }

    @Test func `should give a new session every property its tuning sets`() {
        let session = session()
        let encoder = H264Encoder(fps: 30, bitrate: 2_000_000, tuning: .lowLatency, session: session)

        encoder.encode(frame())

        for property in H264Tuning.lowLatency.properties(bitrate: 2_000_000, fps: 30) {
            verify(session).set(.value(property)).called(1)
        }
    }

    @Test func `should ask for a keyframe on a new session's first frame and when told to`() {
        let keyframe = CompressedFrame(avcc: Data([1]), keyframe: true, sps: Data([0x67, 0x64, 0, 0x1F]), pps: Data([0x68]))
        let session = session(answer: CompressionResult(status: 0, dropped: false, frame: keyframe))
        let encoder = H264Encoder(fps: 30, session: session)

        encoder.encode(frame())
        encoder.encode(frame())
        encoder.encode(frame(), forceKeyframe: true)

        verify(session).submit(.any, at: .any, keyframe: .value(true), done: .any).called(2)
        verify(session).submit(.any, at: .any, keyframe: .value(false), done: .any).called(1)
    }

    @Test func `should fail a frame whose session cannot be opened`() throws {
        let session = MockCompressionSession()
        given(session).open(width: .any, height: .any, lowLatencyRateControl: .any).willReturn(refused)
        let encoder = H264Encoder(fps: 30, session: session)
        let results = Results()

        encoder.encode(frame()) { results.append($0) }

        #expect(results.failed == 1)
        verify(session).submit(.any, at: .any, keyframe: .any, done: .any).called(0)
    }

    @Test func `should fail a frame when its session refuses a property and the caller waits for it`() {
        let session = session(refusing: .realTime(true))
        let encoder = H264Encoder(fps: 30, tuning: .strict, session: session)
        let results = Results()

        encoder.encode(frame()) { results.append($0) }

        #expect(results.failed == 1)
        verify(session).close().called(1)
        verify(session).submit(.any, at: .any, keyframe: .any, done: .any).called(0)
    }

    @Test func `should keep encoding when a property is refused and nobody waits for the frame`() {
        let session = session(refusing: .maxFrameDelayCount(0))
        let encoder = H264Encoder(fps: 30, tuning: .lowLatency, session: session)

        encoder.encode(frame())

        verify(session).submit(.any, at: .any, keyframe: .any, done: .any).called(1)
    }

    @Test func `should retune a live session's frame rate without opening another`() throws {
        let session = session()
        let encoder = H264Encoder(fps: 30, tuning: .lowLatency, session: session)
        encoder.encode(frame())

        try encoder.setFrameRate(60)

        verify(session).set(.value(.expectedFrameRate(60))).called(1)
        verify(session).set(.value(.maxKeyFrameInterval(300))).called(1)
        verify(session).open(width: .any, height: .any, lowLatencyRateControl: .any).called(1)
    }

    @Test func `should refuse a frame rate the session rejects`() {
        let session = session(refusing: .expectedFrameRate(60))
        let encoder = H264Encoder(fps: 30, session: session)
        encoder.encode(frame())

        #expect(throws: (any Error).self) { try encoder.setFrameRate(60) }
    }

    @Test func `should hand back a new session's first keyframe with the avcC record its decoder needs`() throws {
        let sps = Data([0x67, 0x64, 0x00, 0x1F]), pps = Data([0x68, 0xEE])
        let keyframe = CompressedFrame(avcc: Data([0, 0, 0, 1, 0x65]), keyframe: true, sps: sps, pps: pps)
        let encoder = H264Encoder(
            fps: 30, session: session(answer: CompressionResult(status: 0, dropped: false, frame: keyframe)))
        let results = Results()

        encoder.encode(frame()) { results.append($0) }

        let encoded = try #require(results.frames.first)
        #expect(encoded.kind == .keyframe)
        #expect(encoded.avcc == Data([0, 0, 0, 1, 0x65]))
        #expect(encoded.description == AVCDecoderConfigurationRecord.bytes(sps: sps, pps: pps))
    }

    @Test func `should hand back no frame when the encoder drops one`() {
        let encoder = H264Encoder(
            fps: 30, session: session(answer: CompressionResult(status: 0, dropped: true, frame: nil)))
        let results = Results()

        encoder.encode(frame()) { results.append($0) }

        #expect(results.frames.isEmpty && results.failed == 0 && results.empty == 1)
    }

    @Test func `should hand back a delta only after the keyframe that starts its session`() {
        let delta = CompressedFrame(avcc: Data([1]), keyframe: false, sps: nil, pps: nil)
        let encoder = H264Encoder(
            fps: 30, session: session(answer: CompressionResult(status: 0, dropped: false, frame: delta)))
        let results = Results()

        encoder.encode(frame()) { results.append($0) }

        #expect(results.frames.isEmpty && results.empty == 1)
    }

    @Test func `should fail a frame the encoder could not compress`() {
        let encoder = H264Encoder(
            fps: 30, session: session(answer: CompressionResult(status: refused, dropped: false, frame: nil)))
        let results = Results()

        encoder.encode(frame()) { results.append($0) }

        #expect(results.failed == 1)
    }
}

/// Every answer the encoder gave, in order.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Result<H264Encoder.Encoded?, any Error>] = []

    func append(_ result: Result<H264Encoder.Encoded?, any Error>) { lock.withLock { all.append(result) } }

    var frames: [H264Encoder.Encoded] { lock.withLock { all.compactMap { try? $0.get() } } }
    var empty: Int { lock.withLock { all.filter { if case .success(nil) = $0 { true } else { false } }.count } }
    var failed: Int { lock.withLock { all.filter { if case .failure = $0 { true } else { false } }.count } }
}
