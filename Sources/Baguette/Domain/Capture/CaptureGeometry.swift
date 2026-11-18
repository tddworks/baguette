import BaguetteDevice
import Foundation

/// Pixel geometry of one captured frame. The draw rectangle uses a
/// top-left origin and can extend beyond the image when the frame is cropped.
struct CaptureGeometry: Equatable, Sendable {
    let framebufferPixels: RenderDimensions
    let scaledPixels: RenderDimensions
    let placement: CapturePlacement

    var json: [String: Any] {
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
}
