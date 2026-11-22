import BaguetteDevice
import Foundation

/// The Mac's pointer as it looks now — an arrow, an I-beam over text, a hand
/// over a link: its image (PNG), the image's size in points, and the hotspot
/// (the point it points with) within it. Known by an id that follows from its
/// image, so a page fetches each image once. A `baguette pointer-shapes`
/// process says one per change, on its own line:
/// `shape <id> <hotspot x> <hotspot y> <width> <height> <png, base64>`.
struct PointerShape: Equatable, Sendable {
    let id: String
    let hotspot: Point
    let size: Size
    let png: Data

    init(id: String, hotspot: Point, size: Size, png: Data) {
        self.id = id
        self.hotspot = hotspot
        self.size = size
        self.png = png
    }

    /// The shape a line says; nil for any other line.
    init?(line: String) {
        let words = line.split(separator: " ").map(String.init)
        guard words.count == 7, words[0] == "shape",
              let x = Double(words[2]), let y = Double(words[3]),
              let width = Double(words[4]), let height = Double(words[5]),
              let png = Data(base64Encoded: words[6]), !png.isEmpty else { return nil }
        self.init(id: words[1], hotspot: Point(x: x, y: y), size: Size(width: width, height: height), png: png)
    }

    /// The line the process says it in.
    var line: String {
        "shape \(id) \(Self.number(hotspot.x)) \(Self.number(hotspot.y)) "
            + "\(Self.number(size.width)) \(Self.number(size.height)) \(png.base64EncodedString())"
    }

    /// What a page is told: the shape without its image, fetched once by id.
    var json: String {
        #"{"type":"pointer","id":"\#(id)","hotspot":[\#(hotspot.x),\#(hotspot.y)],"size":[\#(size.width),\#(size.height)]}"#
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
