import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("ScreenPlacement")
struct ScreenPlacementTests {
    @Test
    func `should stretch a frame over the screen without cropping or letterboxing`() {
        let placement = DeviceScreenFit.stretch.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))
    }

    @Test
    func `should crop the overflowing width of a wide frame on a square screen when covering`() {
        let placement = DeviceScreenFit.cover.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 0.5, scaleY: 1, offsetX: 0.25, offsetY: 0))
    }

    @Test
    func `should crop the overflowing height of a tall frame on a square screen when covering`() {
        let placement = DeviceScreenFit.cover.placement(
            source: RenderDimensions(width: 100, height: 200),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 0.5, offsetX: 0, offsetY: 0.25))
    }

    @Test
    func `should letterbox a wide frame vertically on a square screen when containing`() {
        let placement = DeviceScreenFit.contain.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 2, offsetX: 0, offsetY: -0.5))
    }

    @Test
    func `should inset the feathered content region from the visible window by the border`() {
        let identity = ScreenPlacement.identity.contentRegion(
            in: RenderDimensions(width: 100, height: 200),
            inset: 2
        )
        #expect(identity == ContentRegion(x: 2, y: 2, width: 96, height: 196))

        // cover crops a wide frame: only the central half of the width is
        // visible, so the border hugs that window instead of the texture.
        let cover = DeviceScreenFit.cover.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        ).contentRegion(in: RenderDimensions(width: 200, height: 100), inset: 2)
        #expect(cover == ContentRegion(x: 52, y: 2, width: 96, height: 96))

        // contain letterboxes: the whole texture is visible.
        let contain = DeviceScreenFit.contain.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        ).contentRegion(in: RenderDimensions(width: 200, height: 100), inset: 2)
        #expect(contain == ContentRegion(x: 2, y: 2, width: 196, height: 96))
    }

    @Test
    func `should leave matching aspect ratios unadjusted when covering or containing`() {
        for fit in [DeviceScreenFit.cover, .contain] {
            let placement = fit.placement(
                source: RenderDimensions(width: 660, height: 1434),
                target: RenderDimensions(width: 1320, height: 2868)
            )

            #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))
        }
    }
}
