import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Baguette
@testable import BaguetteDevice

@Suite("ImageFileCapture")
struct ImageFileCaptureTests {

    /// Class-boxed recorder so the @Sendable onFrame callback can stash
    /// the frames it receives.
    final class Recorder: @unchecked Sendable {
        var frames: [CameraFrame] = []
        func record(_ f: CameraFrame) { frames.append(f) }
    }

    /// Write a solid-grey opaque PNG of the given size to a temp file
    /// and return its path. Big enough (2000×1000) to force a downscale
    /// against the 1280 canvas cap.
    private func writeTempPNG(width: Int, height: Int) throws -> String {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-camtest-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url.path
    }

    @Test func `should refuse to start the image capture when the source is not a still image`() async {
        let capture = ImageFileCapture()
        await #expect(throws: (any Error).self) {
            try await capture.start(source: .video(path: "/tmp/clip.mp4")) { _ in }
        }
    }

    @Test func `should deliver a still image as one fitted, sequenced camera frame`() async throws {
        let path = try writeTempPNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = Recorder()
        let capture = ImageFileCapture()
        try await capture.start(source: .image(path: path)) { recorder.record($0) }
        await capture.stop()

        let first = try #require(recorder.frames.first)
        // 2000×1000 fitted into the 1280 canvas → 1280×640.
        #expect(first.width == 1280)
        #expect(first.height == 640)
        #expect(first.pixels.count == 1280 * 640 * 4)
        #expect(first.sequence == 1)
    }
}
