import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The pointer as it is read many times a second: a shape said once per
/// change, known by an id that follows from its image.
@Suite("PointerShapeChanges")
struct PointerShapeChangesTests {
    let arrow = Data("arrow-image".utf8), beam = Data("beam-image".utf8)
    let png = Data([0x89, 0x50])
    let size = Size(width: 28, height: 40)

    @Test func `should say the pointer's shape the first time it is read`() {
        var changes = PointerShapeChanges()
        let shape = changes.read(image: arrow, png: png, hotspot: Point(x: 4, y: 4), size: size)
        #expect(shape?.hotspot == Point(x: 4, y: 4))
        #expect(shape?.png == png)
    }

    @Test func `should say nothing when the pointer looks as it did`() {
        var changes = PointerShapeChanges()
        _ = changes.read(image: arrow, png: png, hotspot: .init(x: 4, y: 4), size: size)
        #expect(changes.read(image: arrow, png: png, hotspot: .init(x: 4, y: 4), size: size) == nil)
    }

    @Test func `should say a shape again when the pointer changes back to it, by the same id`() {
        var changes = PointerShapeChanges()
        let first = changes.read(image: arrow, png: png, hotspot: .init(x: 4, y: 4), size: size)
        let other = changes.read(image: beam, png: png, hotspot: .init(x: 8, y: 9), size: size)
        let again = changes.read(image: arrow, png: png, hotspot: .init(x: 4, y: 4), size: size)
        #expect(other != nil && other?.id != first?.id)
        #expect(again?.id == first?.id)
    }
}
