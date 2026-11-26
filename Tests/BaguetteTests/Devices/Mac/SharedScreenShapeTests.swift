import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// The display a viewer's device is shared through: the viewer's shape, with
/// as much room for the Mac as they ask for, drawn at twice its points.
@Suite("SharedScreenShape")
struct SharedScreenShapeTests {
    /// An iPhone in portrait: 402 × 874 points at 3 pixels a point.
    let iPhone = ViewerScreen(points: Size(width: 402, height: 874), pixelsPerPoint: 3)

    @Test func `should give a phone a display of its own shape, at its native pixels by default`() {
        let shape = SharedScreenShape(viewer: iPhone, room: .standard)
        #expect(shape.points == Size(width: 603, height: 1311))
        #expect(shape.pixels == Size(width: 1206, height: 2622))
    }

    @Test func `should make the Mac's text the size of the viewer's when asked for larger text`() {
        #expect(SharedScreenShape(viewer: iPhone, room: .largerText).points == Size(width: 402, height: 874))
    }

    @Test func `should give the Mac twice the viewer's room when asked for more space`() {
        #expect(SharedScreenShape(viewer: iPhone, room: .moreSpace).points == Size(width: 804, height: 1748))
    }

    @Test func `should turn the display with the viewer`() {
        let landscape = ViewerScreen(points: Size(width: 874, height: 402), pixelsPerPoint: 3)
        #expect(SharedScreenShape(viewer: landscape, room: .standard).points == Size(width: 1311, height: 603))
    }

    @Test func `should keep a large viewer's display within what the encoder takes, in its shape`() {
        // An iPad Pro 13" in landscape, more space: 2752 × 2064 points would be 5504 pixels wide.
        let iPad = ViewerScreen(points: Size(width: 1376, height: 1032), pixelsPerPoint: 2)
        let shape = SharedScreenShape(viewer: iPad, room: .moreSpace)
        #expect(shape.pixels == Size(width: 4096, height: 3072))
        #expect(shape.points == Size(width: 2048, height: 1536))
    }

    @Test func `should read the room a viewer asks for by its wire name, defaulting to standard`() {
        #expect(SharedScreenShape.Room(wire: "largerText") == .largerText)
        #expect(SharedScreenShape.Room(wire: "moreSpace") == .moreSpace)
        #expect(SharedScreenShape.Room(wire: nil) == .standard)
        #expect(SharedScreenShape.Room(wire: "huge") == nil)
    }

    @Test func `should recognise the display's own mode, two pixels to each of its points`() {
        let shape = SharedScreenShape(viewer: iPhone, room: .standard)
        #expect(shape.isMode(width: 603, height: 1311, pixelWidth: 1206, pixelHeight: 2622))
        #expect(!shape.isMode(width: 1206, height: 2622, pixelWidth: 1206, pixelHeight: 2622))   // the 1× one
        #expect(!shape.isMode(width: 603, height: 1311, pixelWidth: 603, pixelHeight: 1311))
    }
}
