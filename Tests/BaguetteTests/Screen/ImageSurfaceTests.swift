import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Baguette

@Suite("ImageSurface")
struct ImageSurfaceTests {
    @Test func `should draw an image file onto a surface its size`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(
            data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let surface = try #require(ImageSurface.load(url))

        #expect(surface.width == 6)
        #expect(surface.height == 4)
        surface.lock(options: .readOnly, seed: nil)
        let pixel = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        #expect(pixel[2] > 200 && pixel[1] < 30 && pixel[0] < 30)   // BGRA: red
        surface.unlock(options: .readOnly, seed: nil)
    }

    @Test func `should load nothing from a file that isn't an image`() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        FileManager.default.createFile(atPath: url.path, contents: Data("png".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ImageSurface.load(url) == nil)
    }
}
