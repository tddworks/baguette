/// Pixel dimensions accepted by the live video encoding pipeline.
///
/// H.264 uses 4:2:0 chroma planes, so both axes must be even. The value owns
/// that invariant for requested and scaled frames instead of leaking codec
/// mechanics into generic render dimensions.
public struct VideoFrameDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(requested: RenderDimensions) {
        width = requested.width.alignedToEven
        height = requested.height.alignedToEven
    }

    public static func scaling(
        _ source: RenderDimensions,
        by divisor: Int
    ) -> VideoFrameDimensions {
        let divisor = max(1, divisor)
        return VideoFrameDimensions(requested: RenderDimensions(
            width: max(2, source.width / divisor),
            height: max(2, source.height / divisor)
        ))
    }

    public var renderDimensions: RenderDimensions {
        RenderDimensions(width: width, height: height)
    }
}

private extension Int {
    var alignedToEven: Int { isMultiple(of: 2) ? self : self + 1 }
}
