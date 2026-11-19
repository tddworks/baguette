import CoreGraphics
import Foundation
import ImageIO
import IOSurface

/// An image file drawn onto a BGRA surface — the shape every `Screen`
/// hands the encoders — for a screen whose frames arrive as pictures.
public enum ImageSurface {
    public static func load(_ url: URL) -> IOSurface? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return surface(from: image)
    }

    public static func surface(from image: CGImage) -> IOSurface? {
        let (width, height) = (image.width, image.height)
        let bytesPerRow = width * 4
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow, .allocSize: bytesPerRow * height,
            .pixelFormat: 0x42475241,   // 'BGRA'
        ]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }
}
