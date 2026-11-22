import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac's pointer as it looks now — an image, its hotspot and size — as a
/// `baguette pointer-shapes` process says it, one line a change.
@Suite("PointerShape")
struct PointerShapeTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
    static let ibeam = PointerShape(id: "3de4a52b", hotspot: Point(x: 12, y: 11), size: Size(width: 23, height: 22), png: png)

    @Test func `should read a shape the process says, its image and all`() {
        #expect(PointerShape(line: "shape 3de4a52b 12 11 23 22 \(Self.png.base64EncodedString())") == Self.ibeam)
    }

    @Test func `should say a shape as the line the server reads back`() {
        #expect(PointerShape(line: Self.ibeam.line) == Self.ibeam)
    }

    @Test func `should read nothing from any other line, or a shape without its image`() {
        #expect(PointerShape(line: "[baguette] log noise") == nil)
        #expect(PointerShape(line: "shape 3de4a52b 12 11 23 22") == nil)
        #expect(PointerShape(line: "shape 3de4a52b twelve 11 23 22 iVBO") == nil)
        #expect(PointerShape(line: "shape 3de4a52b 12 11 23 22 !!!not-base64") == nil)
    }

    @Test func `should describe itself to a page without its image, which the page fetches once by id`() throws {
        let json = try JSONSerialization.jsonObject(with: Data(Self.ibeam.json.utf8)) as? [String: Any]
        #expect(json?["type"] as? String == "pointer")
        #expect(json?["id"] as? String == "3de4a52b")
        #expect(json?["hotspot"] as? [Double] == [12, 11])
        #expect(json?["size"] as? [Double] == [23, 22])
    }
}
