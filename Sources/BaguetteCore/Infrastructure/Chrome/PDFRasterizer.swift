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

    /// Compose a 9-slice bezel for chrome bundles that don't ship a
    /// pre-baked composite (every iPad bundle, plus `phone13` for
    /// iPhone 17e). Output canvas is `innerSize` expanded by `insets`
    /// on each side; corners stretch into the inset-sized cap rects and
    /// edges fill the gaps between corners. PDFs are drawn as vector
    /// pages so the scaling stays crisp regardless of the source size.
    ///
    /// `innerSize` is the simulator screen's 1× point dimensions
    /// (`mainScreenWidth/Height ÷ mainScreenScale` from the plist).
    /// DeviceKit's `Screen.pdf` ships as a 1×1 marker — meaningless for
    /// sizing — so the caller has to supply the real inner area.
    func compose9Slice(
        pdfs: NineSlicePDFs,
        insets: Insets,
        innerSize: Size
    ) throws -> ChromeImage
}

/// Raw PDF bytes for the eight outer pieces of a 9-slice chrome bundle
/// (4 corners + 4 edges). The center is the simulator's screen area,
/// supplied by the caller as `innerSize` and left transparent in the
/// composed bezel — baguette overlays the live framebuffer on top.
struct NineSlicePDFs: Sendable, Equatable {
    let topLeft: Data
    let top: Data
    let topRight: Data
    let right: Data
    let bottomRight: Data
    let bottom: Data
    let bottomLeft: Data
    let left: Data
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

    func compose9Slice(
        pdfs: NineSlicePDFs,
        insets: Insets,
        innerSize: Size
    ) throws -> ChromeImage {
        // Each piece is rasterized to a CGImage at its native PDF size
        // first, then drawn into its target rect via `ctx.draw(image,
        // in:)` — the bitmap-stretching path. We can't draw the PDFs
        // with `drawPDFPage` + non-uniform CTM scale because CG ignores
        // the per-axis stretch when the page renders, leaking the source
        // outside the target rect (Apple's edge pieces ship as 1×97 /
        // 97×1 strips meant to be stretched perpendicular to their long
        // axis — exactly the case `drawPDFPage` mishandles).
        let topLeft = try rasterizeCG(pdfs.topLeft)
        let top = try rasterizeCG(pdfs.top)
        let topRight = try rasterizeCG(pdfs.topRight)
        let right = try rasterizeCG(pdfs.right)
        let bottomRight = try rasterizeCG(pdfs.bottomRight)
        let bottom = try rasterizeCG(pdfs.bottom)
        let bottomLeft = try rasterizeCG(pdfs.bottomLeft)
        let left = try rasterizeCG(pdfs.left)

        // Canvas = caller-supplied inner area + insets on each side.
        // Insets define the SCREEN INSET (where the front-end overlays
        // the framebuffer), not the bezel thickness — corner art is
        // drawn at native PDF size and extends past the inset into the
        // inner area, where the screen overlay covers it.
        let canvasW = innerSize.width + insets.left + insets.right
        let canvasH = innerSize.height + insets.top + insets.bottom

        let width = Int(canvasW.rounded())
        let height = Int(canvasH.rounded())
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

        // Corners drawn at NATIVE PDF size (e.g. 97×97 for phone13)
        // — they include the rounded outer curve plus enough solid
        // bezel to overlap into the screen-rect area. Assume all four
        // corners share TL's dimensions; holds for every DeviceKit
        // bundle Apple ships.
        let cornerW = CGFloat(topLeft.width)
        let cornerH = CGFloat(topLeft.height)
        let midW = max(canvasW - cornerW * 2, 0)
        let midH = max(canvasH - cornerH * 2, 0)

        // CG origin is bottom-left; layout below is in CG user space.
        let topLeftRect     = CGRect(x: 0,                 y: canvasH - cornerH, width: cornerW, height: cornerH)
        let topRightRect    = CGRect(x: canvasW - cornerW, y: canvasH - cornerH, width: cornerW, height: cornerH)
        let bottomLeftRect  = CGRect(x: 0,                 y: 0,                 width: cornerW, height: cornerH)
        let bottomRightRect = CGRect(x: canvasW - cornerW, y: 0,                 width: cornerW, height: cornerH)
        // Edges stretch perpendicular to their long axis — top/bottom
        // pieces (1×97 native) span midW horizontally; left/right
        // pieces (97×1 native) span midH vertically.
        let topRect    = CGRect(x: cornerW, y: canvasH - cornerH, width: midW,    height: cornerH)
        let bottomRect = CGRect(x: cornerW, y: 0,                 width: midW,    height: cornerH)
        let leftRect   = CGRect(x: 0,                 y: cornerH, width: cornerW, height: midH)
        let rightRect  = CGRect(x: canvasW - cornerW, y: cornerH, width: cornerW, height: midH)

        for (image, target) in [
            (topLeft,     topLeftRect),
            (topRight,    topRightRect),
            (bottomLeft,  bottomLeftRect),
            (bottomRight, bottomRightRect),
            (top,         topRect),
            (bottom,      bottomRect),
            (left,        leftRect),
            (right,       rightRect),
        ] where target.width > 0 && target.height > 0 {
            ctx.draw(image, in: target)
        }

        guard let cgImage = ctx.makeImage() else {
            throw PDFRasterizerError.rasterFailed
        }
        return try ChromeImage(cgImage: cgImage)
    }

    /// Render the first page of a PDF to a `CGImage` at native size.
    /// Used by `compose9Slice` so each piece can be drawn into a
    /// stretched target rect via `ctx.draw(image, in:)`, which handles
    /// non-uniform scale correctly (unlike `drawPDFPage`).
    private func rasterizeCG(_ data: Data) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else {
            throw PDFRasterizerError.invalidPDF
        }
        guard let page = doc.page(at: 1) else {
            throw PDFRasterizerError.noPage
        }
        var box = page.getBoxRect(.cropBox)
        if box.isEmpty { box = page.getBoxRect(.mediaBox) }
        let w = Int(box.width.rounded())
        let h = Int(box.height.rounded())
        guard w > 0, h > 0 else { throw PDFRasterizerError.noPage }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PDFRasterizerError.rasterFailed }
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw PDFRasterizerError.rasterFailed }
        return image
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
