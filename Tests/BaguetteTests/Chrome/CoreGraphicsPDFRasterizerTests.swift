import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Baguette

@Suite("CoreGraphicsPDFRasterizer")
struct CoreGraphicsPDFRasterizerTests {

    @Test func `rasterize returns PNG bytes sized to the PDF crop box`() throws {
        let pdf = try makeSquarePDF(side: 100)
        let rast = CoreGraphicsPDFRasterizer()

        let image = try rast.rasterize(pdfData: pdf)

        #expect(image.size == Size(width: 100, height: 100))
        #expect(Self.hasPNGMagic(image.data))
    }

    @Test func `rasterize throws on non-PDF input`() {
        let rast = CoreGraphicsPDFRasterizer()
        #expect(throws: PDFRasterizerError.self) {
            _ = try rast.rasterize(pdfData: Data("not-a-pdf".utf8))
        }
    }

    @Test func `rasterize throws noPage when the PDF page has zero dimensions`() throws {
        let pdf = try makeSquarePDF(side: 0)
        let rast = CoreGraphicsPDFRasterizer()
        #expect(throws: PDFRasterizerError.noPage) {
            _ = try rast.rasterize(pdfData: pdf)
        }
    }

    // compose stacks layers onto a fresh canvas — produces a PNG sized
    // to canvasSize with the layer drawn at top-left coordinates.
    @Test func `compose draws PNG layers onto a sized canvas`() throws {
        let layerPDF = try makeSquarePDF(side: 50)
        let rast = CoreGraphicsPDFRasterizer()
        let layerImage = try rast.rasterize(pdfData: layerPDF)

        let merged = try rast.compose(
            canvasSize: Size(width: 80, height: 80),
            layers: [ImageLayer(image: layerImage, topLeft: Point(x: 10, y: 20))]
        )
        #expect(merged.size == Size(width: 80, height: 80))
        #expect(Self.hasPNGMagic(merged.data))
    }

    @Test func `compose throws rasterFailed for a zero-sized canvas`() {
        let rast = CoreGraphicsPDFRasterizer()
        #expect(throws: PDFRasterizerError.rasterFailed) {
            _ = try rast.compose(canvasSize: Size(width: 0, height: 0), layers: [])
        }
    }

    @Test func `compose throws decodingFailed when a layer's PNG bytes are unreadable`() {
        let rast = CoreGraphicsPDFRasterizer()
        let busted = ImageLayer(
            image: ChromeImage(data: Data("not-a-png".utf8), size: Size(width: 10, height: 10)),
            topLeft: Point(x: 0, y: 0)
        )
        #expect(throws: PDFRasterizerError.decodingFailed) {
            _ = try rast.compose(
                canvasSize: Size(width: 10, height: 10),
                layers: [busted]
            )
        }
    }

    // MARK: - 9-slice composition

    // Output canvas = `innerSize` + the four insets all around. The
    // chrome.json `sizing` defines the SCREEN INSET — where the
    // simulator's framebuffer sits over the bezel — not the bezel
    // thickness itself. Corner PDFs are drawn at NATIVE PDF size at
    // each canvas corner; their solid bezel art extends past the screen
    // inset into the inner area, where the front-end's screen overlay
    // hides it. Edges stretch between corners along their long axis at
    // native cornerH/cornerW thickness.
    @Test func `compose9Slice produces PNG sized to innerSize plus insets`() throws {
        let rast = CoreGraphicsPDFRasterizer()
        let corner = try makeSquarePDF(side: 96)
        let edge = try makeSquarePDF(side: 2)

        let merged = try rast.compose9Slice(
            pdfs: NineSlicePDFs(
                topLeft: corner, top: edge, topRight: corner,
                right: edge,
                bottomRight: corner, bottom: edge, bottomLeft: corner,
                left: edge
            ),
            insets: Insets(top: 46, left: 46, bottom: 46, right: 46),
            innerSize: Size(width: 834, height: 1210)
        )

        #expect(merged.size == Size(width: 926, height: 1302))
        #expect(Self.hasPNGMagic(merged.data))
    }

    // Precise pixel-level check: a 100×100 corner PDF drawn into a
    // canvas with 30pt insets must paint pixels well past the 30pt
    // inset boundary (because corners are at NATIVE size, not scaled
    // to the cap). Catches the bug where the corner was being squashed
    // into a `sizing × sizing` rect, leaving the visible bezel
    // looking far too thick relative to the inner area.
    @Test func `compose9Slice draws corners at native PDF size, not scaled to insets`() throws {
        let rast = CoreGraphicsPDFRasterizer()
        let corner = try makeSquarePDF(side: 100)
        let edge = try makeSquarePDF(side: 1)
        let merged = try rast.compose9Slice(
            pdfs: NineSlicePDFs(
                topLeft: corner, top: edge, topRight: corner,
                right: edge,
                bottomRight: corner, bottom: edge, bottomLeft: corner,
                left: edge
            ),
            insets: Insets(top: 30, left: 30, bottom: 30, right: 30),
            innerSize: Size(width: 200, height: 200)
        )
        let pixels = try Self.alphaPlane(merged)
        // Canvas: 200 + 30 + 30 = 260. Top-left corner native 100×100
        // sits at the canvas top-left; pixel (60, 60) lies inside the
        // corner native rect (well past the 30pt inset), so it must
        // be opaque. If corners were scaled to 30×30, pixel (60, 60)
        // would land in the inner transparent area → alpha 0.
        #expect(pixels.alpha(x: 60, y: 60) > 200, "corner native art must extend past sizing inset")
        // Pixel deep inside the canvas (x=130, y=130) sits past every
        // corner's reach (max corner reach is x=100; canvasW-cornerW=160,
        // so x=130 is in the inner area not covered by any piece).
        // The center stays transparent — that's where the screen overlay
        // will go.
        #expect(pixels.alpha(x: 130, y: 130) < 32, "inner area must remain transparent for screen overlay")
    }

    @Test func `compose9Slice throws when any piece is not a PDF`() throws {
        let rast = CoreGraphicsPDFRasterizer()
        let valid = try makeSquarePDF(side: 10)
        let bogus = Data("not-a-pdf".utf8)

        #expect(throws: PDFRasterizerError.self) {
            _ = try rast.compose9Slice(
                pdfs: NineSlicePDFs(
                    topLeft: bogus, top: valid, topRight: valid,
                    right: valid,
                    bottomRight: valid, bottom: valid, bottomLeft: valid,
                    left: valid
                ),
                insets: Insets(top: 1, left: 1, bottom: 1, right: 1),
                innerSize: Size(width: 100, height: 100)
            )
        }
    }

    // MARK: - pixel sampling

    /// Decode a `ChromeImage`'s PNG into an alpha plane addressable by
    /// `(x, y)` in top-down image coordinates. Tests use it to assert
    /// where the bezel art ended up — which canvas pixels are opaque
    /// and which stayed transparent for the screen overlay.
    static func alphaPlane(_ image: ChromeImage) throws -> AlphaPlane {
        guard let src = CGImageSourceCreateWithData(image.data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw PDFRasterizerError.decodingFailed
        }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return AlphaPlane(width: w, height: h, bytes: bytes)
    }

    struct AlphaPlane {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 3]
        }
    }

    // MARK: - helpers

    /// Build a single-page PDF with crop box `side × side` so we can
    /// assert the rasterized PNG comes back at the same dimensions.
    private func makeSquarePDF(side: Double) throws -> Data {
        let mutableData = NSMutableData()
        let consumer = CGDataConsumer(data: mutableData)!
        var box = CGRect(x: 0, y: 0, width: side, height: side)
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(box)
        ctx.endPDFPage()
        ctx.closePDF()
        return mutableData as Data
    }

    static func hasPNGMagic(_ data: Data) -> Bool {
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= magic.count else { return false }
        return Array(data.prefix(magic.count)) == magic
    }
}
