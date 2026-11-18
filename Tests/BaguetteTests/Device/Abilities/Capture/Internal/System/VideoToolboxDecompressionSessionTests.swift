import CoreVideo
import Foundation
import IOSurface
import Testing
@testable import BaguetteDevice

/// The real VideoToolbox decompression session under the decoders: a
/// keyframe VideoToolbox just encoded, decoded back into a surface.
@Suite("VideoToolboxDecompressionSession", .tags(.system), .enabled(if: SystemTests.available))
struct VideoToolboxDecompressionSessionTests {

    @Test(.timeLimit(.minutes(1)))
    func `should decode a keyframe into a surface the size of its picture`() throws {
        let keyframe = try Self.keyframe(width: 64, height: 64)
        let decoder = VTH264Decoder()
        let decoded = DispatchSemaphore(value: 0)
        let box = SurfaceBox()
        let description = try #require(keyframe.description)
        try decoder.configure(description: description) { surface in
            box.surface = surface
            decoded.signal()
        }

        decoder.decode(keyframe.avcc)

        #expect(decoded.wait(timeout: .now() + 10) == .success)
        let surface = try #require(box.surface)
        #expect(IOSurfaceGetWidth(surface) == 64 && IOSurfaceGetHeight(surface) == 64)
        decoder.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func `should crop a padded picture to the screen`() throws {
        let keyframe = try Self.keyframe(width: 64, height: 64)
        let description = try #require(keyframe.description)
        let sets = try #require(AVCCParameterSets.parse(avcC: description))
        let decoder = VTStreamDecoder()
        let box = SurfaceBox()
        try decoder.configure(parameterSets: [sets.sps[0], sets.pps[0]], screen: Size(width: 48, height: 32)) {
            box.surface = $0
        }

        decoder.decode(keyframe.avcc)

        let surface = try #require(box.surface)
        #expect(IOSurfaceGetWidth(surface) == 48 && IOSurfaceGetHeight(surface) == 32)
        decoder.stop()
    }

    private static func keyframe(width: Int, height: Int) throws -> H264Encoder.Encoded {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let encoder = H264Encoder(fps: 30, tuning: .strict)
        let answered = DispatchSemaphore(value: 0)
        let box = EncodedBox()
        let frame = try #require(buffer)
        encoder.encode(frame) { result in
            box.result = result
            answered.signal()
        }
        _ = answered.wait(timeout: .now() + 10)
        encoder.stop()
        return try #require(try box.result?.get())
    }
}

private final class SurfaceBox: @unchecked Sendable {
    var surface: IOSurface?
}

private final class EncodedBox: @unchecked Sendable {
    var result: Result<H264Encoder.Encoded?, any Error>?
}
