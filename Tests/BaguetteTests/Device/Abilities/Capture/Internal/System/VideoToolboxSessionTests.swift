import CoreVideo
import Foundation
import Testing
@testable import BaguetteDevice

/// The real VideoToolbox compression session under `H264Encoder`: a frame
/// in, a keyframe out, with the parameter sets a decoder needs.
@Suite("VideoToolboxSession", .tags(.system), .enabled(if: SystemTests.available))
struct VideoToolboxSessionTests {

    @Test(.timeLimit(.minutes(1)))
    func `should compress a first frame into a keyframe that carries its avcC record`() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        let encoder = H264Encoder(fps: 30, tuning: .strict)
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
}

private final class Box: @unchecked Sendable {
    var result: Result<H264Encoder.Encoded?, any Error>?
}
