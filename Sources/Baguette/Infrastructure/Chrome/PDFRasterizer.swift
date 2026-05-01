import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Mockable

/// Inner port for `LiveChromes` — turns PDF bytes into a PNG +
/// pixel-size pair (`ChromeImage`). Mockable so tests don't need to
/// wire CoreGraphics; production uses `CoreGraphicsPDFRasterizer`.
@Mockable
protocol PDFRasterizer: Sendable {
    /// Render the first page of `pdfData` at native scale. Throws if
    /// the bytes aren't a valid PDF or the document has no pages.
    func rasterize(pdfData: Data) throws -> ChromeImage

    /// Stack already-rasterized images onto a canvas of `canvasSize`
    /// and return a single PNG. Layers are drawn in order — the first
    /// entry sits at the back, the last on top. `topLeft` is in canvas
    /// pixel space (origin top-left). `LiveChromes` uses this to bake
    /// chrome buttons behind the device composite into a single
    /// `bezel.png`.
    func compose(canvasSize: Size, layers: [ImageLayer]) throws -> ChromeImage
}

/// One entry in a `compose(...)` call — an already-rasterized
/// `ChromeImage` placed at a top-left point in the destination canvas.
/// Carries the source image's intrinsic size (the rasterizer doesn't
/// re-decode it to figure out where to draw) so callers stay
/// declarative.
struct ImageLayer: Sendable, Equatable {
    let image: ChromeImage
    let topLeft: Point
}

enum PDFRasterizerError: Error, Equatable {
    case invalidPDF
    case noPage
    case rasterFailed
    case encodingFailed
    case decodingFailed
}

/// Production rasterizer — uses `CGPDFDocument` to parse, draws the
/// first page into an RGBA `CGContext`, then encodes the result as
/// PNG via `CGImageDestination`.
///
/// Native PDF page size (the `cropBox`, with `mediaBox` fallback) is
/// honoured 1:1 — chrome PDFs are vector and ship at the resolution
/// the layout JSON expects, so the rasterized PNG is the canonical
/// composite that `DeviceChromeAssets.composite.size` reports.
struct CoreGraphicsPDFRasterizer: PDFRasterizer {

    func rasterize(pdfData: Data) throws -> ChromeImage {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let doc = CGPDFDocument(provider) else {
            throw PDFRasterizerError.invalidPDF
        }
        guard let page = doc.page(at: 1) else {
            throw PDFRasterizerError.noPage
        }

        // cropBox is what the PDF asks readers to display; mediaBox is
        // the physical page. Chrome PDFs set them equal, but cropBox
        // is the right primary because it's authoritative if they
        // ever diverge.
        var box = page.getBoxRect(.cropBox)
        if box.isEmpty { box = page.getBoxRect(.mediaBox) }

        let width = Int(box.width.rounded())
        let height = Int(box.height.rounded())
        guard width > 0, height > 0 else { throw PDFRasterizerError.noPage }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFRasterizerError.rasterFailed
        }

        // Translate so the page's lower-left origin lands at (0,0).
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.drawPDFPage(page)

        guard let cgImage = ctx.makeImage() else {
            throw PDFRasterizerError.rasterFailed
        }
        return try ChromeImage(cgImage: cgImage)
    }

    func compose(canvasSize: Size, layers: [ImageLayer]) throws -> ChromeImage {
        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        guard width > 0, height > 0 else { throw PDFRasterizerError.rasterFailed }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFRasterizerError.rasterFailed
        }

        // CGContext's origin is bottom-left; layer positions are
        // top-left, so flip Y at draw time.
        for layer in layers {
            let cgImage = try decode(layer.image)
            let rect = CGRect(
                x: layer.topLeft.x,
                y: Double(height) - layer.topLeft.y - layer.image.size.height,
                width: layer.image.size.width,
                height: layer.image.size.height
            )
            ctx.draw(cgImage, in: rect)
        }

        guard let cgImage = ctx.makeImage() else {
            throw PDFRasterizerError.rasterFailed
        }
        return try ChromeImage(cgImage: cgImage)
    }

    private func decode(_ image: ChromeImage) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PDFRasterizerError.decodingFailed
        }
        return cg
    }
}

private extension ChromeImage {
    init(cgImage: CGImage) throws {
        let mutable = NSMutableData()
        let pngType = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(
            mutable, pngType, 1, nil
        ) else {
            throw PDFRasterizerError.encodingFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PDFRasterizerError.encodingFailed
        }
        self.init(
            data: mutable as Data,
            size: Size(width: Double(cgImage.width), height: Double(cgImage.height))
        )
    }
}
