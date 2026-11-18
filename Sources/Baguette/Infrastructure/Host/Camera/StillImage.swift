import Foundation
import CoreGraphics
import ImageIO

/// Decodes a host image file into a single tightly-packed BGRA
/// `CameraFrame`, downscaled to fit the shared canvas. The irreducible
/// I/O — `CGImageSource` decode + a `CGContext` render — is here;
/// the fit *decision* is the pure `ScaleToFit`, the pixel layout is the
/// same premultiplied-first / little-endian BGRA the dylib's
/// `SharedFrameReader` reads and the webcam path produces.
enum StillImage {

    /// Load `path`, fit it into `max × max`, and pack it BGRA. The
    /// returned frame carries sequence 1 as a seed — `ImageFileCapture`
    /// resequences it on every re-emit.
    static func load(path: String, max: Int) throws -> CameraFrame {
        let url = URL(fileURLWithPath: path)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw StillImageError.decodeFailed(path)
        }

        let fitted = ScaleToFit.fit(width: image.width, height: image.height, max: max)
        let width = fitted.width, height = fitted.height
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)

        try pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw StillImageError.contextCreationFailed
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return try CameraFrame(
            sequence: 1,
            timestampMs: 0,
            width: UInt32(width),
            height: UInt32(height),
            pixels: pixels
        )
    }
}

/// `LocalizedError` as well as `CustomStringConvertible`: `CameraSession`
/// reports a failed start to the browser as `error.localizedDescription`,
/// and that bridge ignores `description` — without `errorDescription` the
/// socket shows Foundation's "The operation couldn't be completed.
/// (Baguette.StillImageError error 0.)" instead of the reason.
enum StillImageError: LocalizedError, Equatable, CustomStringConvertible {
    case decodeFailed(String)
    case contextCreationFailed

    var description: String {
        switch self {
        case .decodeFailed(let path): return "still image: could not decode '\(path)'"
        case .contextCreationFailed: return "still image: could not create a BGRA context"
        }
    }

    var errorDescription: String? { description }
}
