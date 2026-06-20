import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import IOSurface

/// Stateless JPEG encoder. Wraps an `IOSurface` zero-copy into a
/// `CVPixelBuffer`, lifts it through `CGImage`, and writes JPEG bytes via
/// `CGImageDestination`. Quality is configurable; default tracks the
/// shipping CLI default (0.40).
struct JPEGEncoder {
    let quality: Double

    init(quality: Double = 0.7) { self.quality = quality }

    /// Convenience: wrap the IOSurface zero-copy and encode.
    func encode(_ surface: IOSurface) -> Data? {
        var buffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer?.takeRetainedValue() else {
            return nil
        }
        return encode(pixelBuffer)
    }

    /// Encode an arbitrary CVPixelBuffer (e.g. one produced by `Scaler`).
    func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                        CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
