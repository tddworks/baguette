import BaguetteDevice
/// Pixel dimensions accepted by the live video encoding pipeline.
///
/// H.264 uses 4:2:0 chroma planes, so both axes must be even. The value owns
/// that invariant for requested and scaled frames instead of leaking codec
/// mechanics into generic render dimensions.
struct VideoFrameDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    init(requested: RenderDimensions) {
        width = requested.width.alignedToEven
        height = requested.height.alignedToEven
    }

    static func scaling(
        _ source: RenderDimensions,
        by divisor: Int
    ) -> VideoFrameDimensions {
        let divisor = max(1, divisor)
        return VideoFrameDimensions(requested: RenderDimensions(
            width: max(2, source.width / divisor),
            height: max(2, source.height / divisor)
        ))
    }

    var renderDimensions: RenderDimensions {
        RenderDimensions(width: width, height: height)
    }
}

private extension Int {
    var alignedToEven: Int { isMultiple(of: 2) ? self : self + 1 }
}
