import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("VideoFrameDimensions")
struct VideoFrameDimensionsTests {
    @Test func `should align requested dimensions for 4 2 0 video frames`() {
        let dimensions = VideoFrameDimensions(
            requested: RenderDimensions(width: 669, height: 1047)
        )

        #expect(dimensions.width == 670)
        #expect(dimensions.height == 1048)
        #expect(dimensions.renderDimensions == RenderDimensions(width: 670, height: 1048))
    }

    @Test func `should scale before applying codec alignment`() {
        let dimensions = VideoFrameDimensions.scaling(
            RenderDimensions(width: 670, height: 1048),
            by: 2
        )

        #expect(dimensions == VideoFrameDimensions(
            requested: RenderDimensions(width: 336, height: 524)
        ))
    }
}
