import Testing
import CoreImage
import CoreVideo
import Foundation
import IOSurface
@testable import Baguette
@testable import BaguetteDevice

/// `AVAssetWriterReel` is integration-only where it talks to
/// `AVAssetWriter` — but the one decision it *does* make on its own is
/// where each simulator frame's pixels land on the video canvas, and
/// that is a pure function of the `CapturePlacement` it was opened with.
///
/// It matters because the two coordinate systems disagree. A
/// `CapturePlacement` counts `drawY` **down from the top** (the browser's
/// canvas convention, which `CaptureCanvas` and `capture-size.js` both
/// speak); Core Image counts **up from the bottom**. Skipping the mirror
/// is invisible on a symmetric letterbox and quietly wrong on every
/// odd-pixel canvas and every `cover` crop — the exact note
/// `CaptureCanvas.compose` already carries. These tests hold the
/// recording path to the same convention as the screenshot path.
@Suite("AVAssetWriterReel")
struct AVAssetWriterReelTests {

    @Test func `should paint the frame at the bottom when it is letterboxed to the bottom of the canvas`() throws {
        // 4×4 frame: red on top, blue underneath. Placed into the lower
        // half of a 4×8 canvas over a green mat.
        let surface = try stripedSurface()
        let placement = CapturePlacement(
            width: 4, height: 8,
            drawX: 0, drawY: 4, drawWidth: 4, drawHeight: 4
        )

        let grid = try render(surface, placement: placement)

        // Top half is mat…
        #expect(grid.pixel(x: 2, y: 1) == Pixel(r: 0, g: 255, b: 0, a: 255))
        // …and the frame sits under it, still the right way up.
        #expect(grid.pixel(x: 2, y: 5) == Pixel(r: 255, g: 0, b: 0, a: 255))
        #expect(grid.pixel(x: 2, y: 7) == Pixel(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func `should paint the frame at the top when it is letterboxed to the top of the canvas`() throws {
        let surface = try stripedSurface()
        let placement = CapturePlacement(
            width: 4, height: 8,
            drawX: 0, drawY: 0, drawWidth: 4, drawHeight: 4
        )

        let grid = try render(surface, placement: placement)

        #expect(grid.pixel(x: 2, y: 0) == Pixel(r: 255, g: 0, b: 0, a: 255))
        #expect(grid.pixel(x: 2, y: 3) == Pixel(r: 0, g: 0, b: 255, a: 255))
        #expect(grid.pixel(x: 2, y: 6) == Pixel(r: 0, g: 255, b: 0, a: 255))
    }

    @Test func `should keep the part of the frame the placement points at when cropping`() throws {
        // The frame overhangs the canvas by its bottom half. At 1:1
        // there is no resampling to blur the answer: what survives is
        // the frame's *top* rows, because that is where `drawY: 0`
        // anchors it. Reading `drawY` as a bottom-up offset would keep
        // the blue half instead — the tell that the mirror is missing.
        let surface = try stripedSurface()
        let placement = CapturePlacement(
            width: 4, height: 2,
            drawX: 0, drawY: 0, drawWidth: 4, drawHeight: 4
        )

        let grid = try render(surface, placement: placement)

        // No mat anywhere — the frame covers the whole canvas.
        #expect(grid.pixel(x: 2, y: 0) == Pixel(r: 255, g: 0, b: 0, a: 255))
        #expect(grid.pixel(x: 2, y: 1) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func `should fill the letterbox with the requested background colour, opaque`() throws {
        let surface = try stripedSurface()
        let placement = CapturePlacement(
            width: 8, height: 4,
            drawX: 2, drawY: 0, drawWidth: 4, drawHeight: 4
        )

        let grid = try render(
            surface, placement: placement, background: HexColor("#102030")
        )

        #expect(grid.pixel(x: 0, y: 2) == Pixel(r: 0x10, g: 0x20, b: 0x30, a: 255))
        #expect(grid.pixel(x: 7, y: 2) == Pixel(r: 0x10, g: 0x20, b: 0x30, a: 255))
        #expect(grid.pixel(x: 4, y: 2) != Pixel(r: 0x10, g: 0x20, b: 0x30, a: 255))
    }

    // MARK: - What lands at the user's path

    @Test func `should leave an existing file alone when a take has no frames`() async throws {
        // The classic re-run: yesterday's good clip is sitting at
        // `--output`, today's take captures nothing. Deleting the good
        // one to make room for a file that never got written is the
        // worst of both outcomes, so the reel writes somewhere else
        // until it has something worth handing over.
        let destination = try scratchDirectory().appendingPathComponent("demo.mp4")
        try Data("yesterday's take".utf8).write(to: destination)

        let reel = AVAssetWriterReel()
        try reel.open(
            to: destination,
            placement: CapturePlacement(
                width: 64, height: 64, drawX: 0, drawY: 0, drawWidth: 64, drawHeight: 64
            ),
            plan: makePlan()
        )
        reel.discard()

        #expect(try Data(contentsOf: destination) == Data("yesterday's take".utf8))
        #expect(try siblings(of: destination) == ["demo.mp4"])
    }

    @Test func `should replace whatever was at the output path when a take finishes`() async throws {
        let destination = try scratchDirectory().appendingPathComponent("demo.mp4")
        try Data("yesterday's take".utf8).write(to: destination)

        let reel = AVAssetWriterReel()
        try reel.open(
            to: destination,
            placement: CapturePlacement(
                width: 64, height: 64, drawX: 0, drawY: 0, drawWidth: 64, drawHeight: 64
            ),
            plan: makePlan()
        )
        #expect(reel.append(frame: try squareSurface(), at: 0))
        try await reel.close()

        let written = try Data(contentsOf: destination)
        #expect(written.count > 500)
        // An MP4's file-type box sits at bytes 4…8.
        #expect(written[4..<8] == Data("ftyp".utf8))
        // Nothing left over beside it either way.
        #expect(try siblings(of: destination) == ["demo.mp4"])
    }

    // MARK: - Fixtures

    private func makePlan() -> RecordingPlan {
        RecordingPlan(
            size: .native, fit: .contain, background: HexColor("#ffffff"),
            fps: 30, bitrateBps: 2_000_000, duration: nil, format: .mp4
        )
    }

    /// A fresh directory per test, so "what else is in here" is a
    /// question with an answer.
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-reel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    /// Every entry in the file's directory, hidden ones included.
    private func siblings(of url: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .sorted()
    }

    private func squareSurface() throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: 64,
            .height: 64,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]))
    }

    /// A 4×4 framebuffer: rows 0–1 red, rows 2–3 blue. Written in raster
    /// order, top row first — exactly how the simulator hands one over.
    private func stripedSurface() throws -> IOSurface {
        let surface = try #require(IOSurface(properties: [
            .width: 4,
            .height: 4,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]))
        surface.lock(options: [], seed: nil)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let stride = surface.bytesPerRow
        for y in 0..<4 {
            for x in 0..<4 {
                let i = y * stride + x * 4
                let top = y < 2
                base[i] = top ? 0 : 255      // blue
                base[i + 1] = 0              // green
                base[i + 2] = top ? 255 : 0  // red
                base[i + 3] = 255
            }
        }
        surface.unlock(options: [], seed: nil)
        return surface
    }

    private func render(
        _ surface: IOSurface,
        placement: CapturePlacement,
        background: HexColor = HexColor("#00ff00")
    ) throws -> PixelGrid {
        let image = AVAssetWriterReel.compose(
            surface, placement: placement, over: background
        )
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let cgImage = try #require(context.createCGImage(
            image,
            from: CGRect(x: 0, y: 0, width: placement.width, height: placement.height)
        ))
        return try sampled(cgImage)
    }

    private func sampled(_ image: CGImage) throws -> PixelGrid {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { throw ReelTestFailure.contextFailed }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return PixelGrid(width: width, height: height, bytes: bytes)
    }
}

private enum ReelTestFailure: Error { case contextFailed }

private struct Pixel: Equatable {
    let r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

private struct PixelGrid {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// `y` counts from the top, matching how a placement talks.
    func pixel(x: Int, y: Int) -> Pixel {
        let i = (y * width + x) * 4
        // premultipliedFirst + byteOrder32Little == B, G, R, A in memory.
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i], a: bytes[i + 3])
    }
}
