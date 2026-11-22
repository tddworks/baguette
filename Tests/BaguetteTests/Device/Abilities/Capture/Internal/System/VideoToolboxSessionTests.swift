import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import BaguetteDevice

/// The real VideoToolbox compression session under `VideoEncoder`: a frame
/// in, a keyframe out, with the parameter sets a decoder needs.
@Suite("VideoToolboxSession", .tags(.system), .enabled(if: SystemTests.available))
struct VideoToolboxSessionTests {

    @Test(.timeLimit(.minutes(1)))
    func `should compress a first frame into a keyframe that carries its avcC record`() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        let encoder = VideoEncoder(fps: 30, tuning: .strict)
        let answered = DispatchSemaphore(value: 0)
        let box = Box()

        encoder.encode(frame) { result in
            box.result = result
            answered.signal()
        }

        #expect(answered.wait(timeout: .now() + 10) == .success)
        let encoded = try #require(try box.result?.get())
        #expect(encoded.kind == .keyframe)
        #expect(encoded.description?.first == 0x01)
        #expect(!encoded.avcc.isEmpty)
        encoder.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func `should hand back the encoder's own avcC record, holding one SPS and one PPS`() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let picture = try #require(buffer)
        let session = VideoToolboxSession()
        #expect(session.open(width: 64, height: 64, codec: kCMVideoCodecType_H264, lowLatencyRateControl: false) == 0)
        #expect(session.set(.highProfileAutoLevel) == 0)
        #expect(session.prepare() == 0)
        let answered = DispatchSemaphore(value: 0)
        let box = FrameBox()
        _ = session.submit(picture, at: .zero, keyframe: true) { result in
            box.frame = result.frame
            answered.signal()
        }
        #expect(answered.wait(timeout: .now() + 10) == .success)
        let frame = try #require(box.frame)
        let record = try #require(frame.records["avcC"])
        let sets = try #require(H264Codec().parameterSets(record: record))
        #expect(sets.map { $0.first.map { $0 & 0x1F } } == [7, 8])   // SPS, PPS
        session.close()
    }
}

private final class Box: @unchecked Sendable {
    var result: Result<VideoEncoder.Encoded?, any Error>?
}

private final class FrameBox: @unchecked Sendable {
    var frame: CompressedFrame?
}
