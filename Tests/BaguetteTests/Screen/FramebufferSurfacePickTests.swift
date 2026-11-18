import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Given a display binding and live surface sizes, pick which plane to
/// emit. CarPlay must never fall back to the phone framebuffer.
@Suite("FramebufferSurfacePick")
struct FramebufferSurfacePickTests {
    private let phoneBinding = DisplayBinding(
        kind: .phone,
        connectedScreenId: 1,
        portName: "com.apple.framebuffer.display",
        size: Size(width: 1206, height: 2622)
    )
    private let carPlayBinding = DisplayBinding(
        kind: .carPlay,
        connectedScreenId: 2,
        portName: "com.apple.framebuffer.display",
        size: Size(width: 800, height: 480)
    )

    @Test func `should capture the phone from the surface closest to its bound size`() {
        let index = FramebufferSurfacePick.index(
            binding: phoneBinding,
            candidates: [
                Size(width: 100, height: 100),
                Size(width: 1206, height: 2622),
                Size(width: 800, height: 480),
            ]
        )
        #expect(index == 1)
    }

    @Test func `should capture CarPlay from the landscape surface near its bound size, skipping the phone`() {
        let index = FramebufferSurfacePick.index(
            binding: carPlayBinding,
            candidates: [
                Size(width: 1206, height: 2622),
                Size(width: 800, height: 480),
                Size(width: 100, height: 100),
            ]
        )
        #expect(index == 1)
    }

    @Test func `should find no CarPlay surface when only phone surfaces are present`() {
        let index = FramebufferSurfacePick.index(
            binding: carPlayBinding,
            candidates: [
                Size(width: 1206, height: 2622),
                Size(width: 1179, height: 2556),
            ]
        )
        #expect(index == nil)
    }

    /// The external plane used to refuse anything above 800×480×4 —
    /// a leftover from when this pane was only ever CarPlay, whose
    /// screen is 720×480. The I/O → External Displays menu offers
    /// ordinary resolutions too, and a 1080p one is a perfectly good
    /// display to stream; rejecting it just reported "nothing attached"
    /// at a screen the user was looking at.
    @Test func `should accept a full-HD or 4K external surface`() {
        #expect(FramebufferSurfacePick.acceptsExternal(Size(width: 1920, height: 1080)))
        #expect(FramebufferSurfacePick.acceptsExternal(Size(width: 3840, height: 2160)))
    }

    /// Landscape is the check that still earns its keep: it is what
    /// keeps a portrait phone plane out of the external pane when the
    /// largest-area heuristic has already spent itself on some other
    /// port. Mirroring SpringBoard into the external pane is worse than
    /// showing nothing, because it looks like it worked.
    @Test func `should never accept a portrait surface as external`() {
        #expect(!FramebufferSurfacePick.acceptsExternal(Size(width: 1206, height: 2622)))
        #expect(!FramebufferSurfacePick.acceptsExternal(Size(width: 1179, height: 2556)))
    }

    /// Landscape means *wider than tall*. A square is neither the
    /// device's shape nor a display's, and admitting it means any square
    /// scratch buffer big enough to clear the area floor can bind as the
    /// external plane.
    @Test func `should not accept a square surface as external`() {
        #expect(!FramebufferSurfacePick.acceptsExternal(Size(width: 512, height: 512)))
        #expect(!FramebufferSurfacePick.acceptsExternal(Size(width: 1080, height: 1080)))
    }

    @Test func `should not accept a degenerate sliver as external`() {
        #expect(!FramebufferSurfacePick.acceptsExternal(Size(width: 100, height: 100)))
        #expect(!FramebufferSurfacePick.acceptsExternal(Size(width: 0, height: 0)))
    }

    @Test func `should capture a large external screen from the large landscape surface`() {
        let binding = DisplayBinding(
            kind: .carPlay,
            connectedScreenId: 2,
            portName: "com.apple.framebuffer.display",
            size: Size(width: 1920, height: 1080)
        )
        let index = FramebufferSurfacePick.index(
            binding: binding,
            candidates: [
                Size(width: 1206, height: 2622),
                Size(width: 1920, height: 1080),
            ]
        )
        #expect(index == 1)
    }

    @Test func `should capture the largest surface when no screen is bound`() {
        let index = FramebufferSurfacePick.index(
            binding: nil,
            candidates: [
                Size(width: 800, height: 480),
                Size(width: 1206, height: 2622),
            ]
        )
        #expect(index == 1)
    }
}
