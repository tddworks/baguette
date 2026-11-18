import CoreImage
import CoreVideo
import Foundation
import IOSurface

/// Projects an IOSurface into a pooled, codec-ready video frame.
///
/// The projection optionally downsamples, preserves the domain's chroma-plane
/// dimension invariant, and publishes Core Image's GPU write before a
/// synchronous JPEG or asynchronous VideoToolbox consumer reads the buffer.
final class VideoFrameScaler {
    private let context = CIContext(options: [.priorityRequestLow: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: VideoFrameDimensions?

    func scale(_ surface: IOSurface, by divisor: Int) -> CVPixelBuffer? {
        let source = RenderDimensions(
            width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface)
        )
        let size = VideoFrameDimensions.scaling(source, by: divisor)

        if pool == nil || size != poolSize {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }

        let image = CIImage(ioSurface: surface)
        let transform = CGAffineTransform(
            scaleX: CGFloat(size.width) / CGFloat(source.width),
            y: CGFloat(size.height) / CGFloat(source.height)
        )
        context.render(image.transformed(by: transform), to: output)

        CVPixelBufferLockBaseAddress(output, [])
        CVPixelBufferUnlockBaseAddress(output, [])
        return output
    }
}
