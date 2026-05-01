import Testing
import Foundation
import CoreGraphics
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
