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
