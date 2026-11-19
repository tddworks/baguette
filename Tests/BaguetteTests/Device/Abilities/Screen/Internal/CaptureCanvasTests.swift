import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
@testable import Baguette
@testable import BaguetteDevice

/// `CaptureCanvas` is the CoreGraphics half of the capture-size
/// vocabulary: it takes the frame baguette grabbed and re-lays it onto
/// the canvas the user asked for. The geometry is `CapturePlacement`'s
/// job and already covered by `CaptureSizeTests` — what's asserted here
/// is that the *pixels* land where the placement says: the letterbox
/// bars really are the background colour, `cover` really crops, and a
/// native capture really is left alone rather than resampled.
@Suite("CaptureCanvas")
struct CaptureCanvasTests {

    // ── contain ──────────────────────────────────────────────

    @Test func `should letterbox the frame onto the background when fit is contain`() throws {
        // 100×50 all-red frame asked for a square: the ratio grows the
        // binding axis to 100×100, so 25px of background sits above and
        // below the centred frame.
        let source = solid(width: 100, height: 50, red: 255, green: 0, blue: 0)
        let out = try #require(CaptureCanvas.apply(
            size: try CaptureSize.parse("square"), fit: .contain,
            background: "#0000ff", to: source
        ))

        #expect(out.width == 100)
        #expect(out.height == 100)
        let grid = try samples(of: out)
        #expect(grid.pixel(x: 50, y: 5) == Pixel(r: 0, g: 0, b: 255, a: 255))
        #expect(grid.pixel(x: 50, y: 95) == Pixel(r: 0, g: 0, b: 255, a: 255))
        #expect(grid.pixel(x: 50, y: 50) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func `should leave the letterbox bars clear when the background is transparent`() throws {
        let source = solid(width: 100, height: 50, red: 255, green: 0, blue: 0)
        let out = try #require(CaptureCanvas.apply(
            size: try CaptureSize.parse("square"), fit: .contain,
            background: "transparent", to: source
        ))
        let grid = try samples(of: out)
        #expect(grid.pixel(x: 50, y: 5).a == 0)
        #expect(grid.pixel(x: 50, y: 50).a == 255)
    }

    // ── cover ────────────────────────────────────────────────

    @Test func `should crop the overflow instead of letterboxing when fit is cover`() throws {
        // Left half red, right half green. 100×50 → square under cover
        // scales ×2 and centres, so the visible window is source x 25…75:
        // the canvas keeps red on the left, green on the right, and no
        // background ever shows.
        let source = halves(width: 100, height: 50)
        let out = try #require(CaptureCanvas.apply(
            size: try CaptureSize.parse("square"), fit: .cover,
            background: "#0000ff", to: source
        ))

        #expect(out.width == 100)
        #expect(out.height == 100)
        let grid = try samples(of: out)
        #expect(grid.pixel(x: 5, y: 50) == Pixel(r: 255, g: 0, b: 0, a: 255))
        #expect(grid.pixel(x: 95, y: 50) == Pixel(r: 0, g: 255, b: 0, a: 255))
        #expect(grid.pixel(x: 50, y: 2).b != 255)
        #expect(grid.pixel(x: 50, y: 97).b != 255)
    }

    // ── stretch ──────────────────────────────────────────────

    @Test func `should fill the whole canvas, distorting the frame, when fit is stretch`() throws {
        let source = solid(width: 100, height: 50, red: 255, green: 0, blue: 0)
        let out = try #require(CaptureCanvas.apply(
            size: try CaptureSize.parse("square"), fit: .stretch,
            background: "#0000ff", to: source
        ))
        let grid = try samples(of: out)
        #expect(grid.pixel(x: 2, y: 2) == Pixel(r: 255, g: 0, b: 0, a: 255))
        #expect(grid.pixel(x: 97, y: 97) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    // ── native ───────────────────────────────────────────────

    @Test func `should hand back the very same frame when the capture size is native`() throws {
        let source = solid(width: 100, height: 50, red: 255, green: 0, blue: 0)
        let out = CaptureCanvas.apply(
            size: .native, fit: .contain, background: "#0000ff", to: source
        )
        #expect(out === source)
    }

    // ── fixed sizes ──────────────────────────────────────────

    @Test func `should capture at exactly the requested pixels when a fixed size is asked for`() throws {
        let source = solid(width: 100, height: 50, red: 255, green: 0, blue: 0)
        let out = try #require(CaptureCanvas.apply(
            size: try CaptureSize.parse("40x80"), fit: .contain,
            background: "#0000ff", to: source
        ))
        #expect(out.width == 40)
        #expect(out.height == 80)
    }

    // ── lifting a framebuffer ────────────────────────────────

    @Test func `should keep a captured frame's pixels after the framebuffer moves on`() throws {
        // SimulatorKit keeps rendering into the surface it handed us —
        // `screen.stop()` only lands after the capture returns. A lifted
        // frame that still aliased that memory would encode a torn mix of
        // two frames, so the lift has to own its bytes.
        let buffer = try #require(pixelBuffer(width: 8, height: 4, red: 255, green: 0, blue: 0))
        let lifted = try #require(CaptureCanvas.image(from: buffer))

        overwrite(buffer, red: 0, green: 0, blue: 255)

        let grid = try samples(of: lifted)
        #expect(grid.pixel(x: 4, y: 2) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    // ── background parsing ───────────────────────────────────

    @Test func `should treat a transparent background as no background colour`() {
        #expect(CaptureCanvas.background("transparent") == nil)
        #expect(CaptureCanvas.background("#0000ff") == HexColor(red: 0, green: 0, blue: 1))
    }

    // ── encoding ─────────────────────────────────────────────

    @Test func `should encode a capture as PNG`() throws {
        let source = solid(width: 8, height: 4, red: 255, green: 0, blue: 0)
        let data = try #require(CaptureCanvas.encode(source, format: .png, quality: 0.85))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(try decodedSize(data) == CGSize(width: 8, height: 4))
    }

    @Test func `should encode a capture as JPEG`() throws {
        let source = solid(width: 8, height: 4, red: 255, green: 0, blue: 0)
        let data = try #require(CaptureCanvas.encode(source, format: .jpeg, quality: 0.85))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try decodedSize(data) == CGSize(width: 8, height: 4))
    }

    // ── format choice ────────────────────────────────────────

    @Test func `should prefer an explicitly named format over the output extension`() {
        #expect(CaptureFormat.resolve(explicit: .jpeg, output: "/tmp/shot.png") == .jpeg)
    }

    @Test func `should capture PNG when the output path ends in .png and no format is named`() {
        #expect(CaptureFormat.resolve(explicit: nil, output: "/tmp/shot.PNG") == .png)
    }

    @Test func `should default to JPEG for stdout and every other output extension`() {
        #expect(CaptureFormat.resolve(explicit: nil, output: nil) == .jpeg)
        #expect(CaptureFormat.resolve(explicit: nil, output: "/tmp/shot.jpg") == .jpeg)
    }

    @Test func `should accept png, jpg and jpeg as format names and reject others`() {
        #expect(CaptureFormat(argument: "png") == .png)
        #expect(CaptureFormat(argument: "jpg") == .jpeg)
        #expect(CaptureFormat(argument: "jpeg") == .jpeg)
        #expect(CaptureFormat(argument: "gif") == nil)
    }
}

// MARK: - Synthetic frames

/// One sampled pixel, read back out of a known BGRA layout.
private struct Pixel: Equatable {
    let r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

private struct PixelGrid {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// `y` counts from the top, matching how the placement talks.
    func pixel(x: Int, y: Int) -> Pixel {
        let i = (y * width + x) * 4
        // premultipliedFirst + byteOrder32Little == B, G, R, A in memory.
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i], a: bytes[i + 3])
    }
}

/// A solid-colour BGRA image — the simplest stand-in for a framebuffer.
private func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
    image(width: width, height: height) { _, _ in (red, green, blue) }
}

/// Left half red, right half green — enough asymmetry to prove a crop
/// took the middle and not an edge.
private func halves(width: Int, height: Int) -> CGImage {
    image(width: width, height: height) { x, _ in
        x < width / 2 ? (255, 0, 0) : (0, 255, 0)
    }
}

private func image(
    width: Int, height: Int,
    fill: (Int, Int) -> (UInt8, UInt8, UInt8)
) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = fill(x, y)
            let i = (y * width + x) * 4
            bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r; bytes[i + 3] = 255
        }
    }
    let made: CGImage? = bytes.withUnsafeMutableBytes { raw in
        CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )?.makeImage()
    }
    return made!
}

/// A BGRA pixel buffer standing in for a live framebuffer — one that
/// the test can then scribble over, the way the simulator does.
private func pixelBuffer(
    width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8
) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
    ) == kCVReturnSuccess, let buffer else { return nil }
    overwrite(buffer, red: red, green: green, blue: blue)
    return buffer
}

private func overwrite(_ buffer: CVPixelBuffer, red: UInt8, green: UInt8, blue: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<CVPixelBufferGetHeight(buffer) {
        for x in 0..<CVPixelBufferGetWidth(buffer) {
            let i = y * stride + x * 4
            bytes[i] = blue; bytes[i + 1] = green; bytes[i + 2] = red; bytes[i + 3] = 255
        }
    }
}

/// Rasterize back into a known BGRA layout so pixels can be asserted.
private func samples(of image: CGImage) throws -> PixelGrid {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw CaptureCanvasTestFailure.contextFailed }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return PixelGrid(width: width, height: height, bytes: bytes)
}

private func decodedSize(_ data: Data) throws -> CGSize {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return CGSize(width: image.width, height: image.height)
}

private enum CaptureCanvasTestFailure: Error { case contextFailed }
