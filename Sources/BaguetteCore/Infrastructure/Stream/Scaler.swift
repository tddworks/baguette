import Foundation
import CoreImage
import CoreVideo
import IOSurface

/// Downscales an `IOSurface` by an integer divisor into a smaller
/// `CVPixelBuffer`. VT then encodes that smaller buffer, producing a
/// smaller bitstream — the user-visible effect of `StreamConfig.scale`.
///
/// Scale 1 is a no-op for the caller (use the surface zero-copy via
/// `CVPixelBufferCreateWithIOSurface` directly). Scale ≥ 2 routes through
/// this helper.
final class Scaler {
    private let context = CIContext(options: [.priorityRequestLow: false])
    private var pool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    /// Returns a fresh `CVPixelBuffer` with `surface` rendered into it at
    /// 1/`scale` size on each axis. Returns nil on allocation failure.
    func downscale(_ surface: IOSurface, scale: Int) -> CVPixelBuffer? {
        let srcW = IOSurfaceGetWidth(surface)
        let srcH = IOSurfaceGetHeight(surface)
        let dstW = max(2, srcW / scale)
        let dstH = max(2, srcH / scale)

        if pool == nil || dstW != poolWidth || dstH != poolHeight {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: dstW,
                kCVPixelBufferHeightKey: dstH,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolWidth = dstW
            poolHeight = dstH
        }
        guard let pool else { return nil }

        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let dst = pbOut else { return nil }

        let src = CIImage(ioSurface: surface)
        let sx = CGFloat(dstW) / CGFloat(srcW)
        let sy = CGFloat(dstH) / CGFloat(srcH)
        context.render(src.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: dst)
        return dst
    }
}
