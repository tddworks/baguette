import Foundation

/// Pixel geometry of one captured frame. The draw rectangle uses a
/// top-left origin and can extend beyond the image when the frame is cropped.
public struct CaptureGeometry: Equatable, Sendable {
    public let framebufferPixels: RenderDimensions
    public let scaledPixels: RenderDimensions
    public let placement: CapturePlacement

    public var json: [String: Any] {
        [
            "framebufferPixels": ["width": framebufferPixels.width, "height": framebufferPixels.height],
            "scaledPixels": ["width": scaledPixels.width, "height": scaledPixels.height],
            "imagePixels": ["width": placement.width, "height": placement.height],
            "drawRectPixels": [
                "x": placement.drawX, "y": placement.drawY,
                "width": placement.drawWidth, "height": placement.drawHeight,
            ],
        ]
    }

    public init(framebufferPixels: RenderDimensions, scaledPixels: RenderDimensions, placement: CapturePlacement) {
        self.framebufferPixels = framebufferPixels
        self.scaledPixels = scaledPixels
        self.placement = placement
    }
}
