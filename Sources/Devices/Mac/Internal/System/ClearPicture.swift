import BaguetteDevice
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A fully transparent PNG of a size — the picture a display with no frame is
/// drawn in. Integration-only: what it's for is `MacDisplayLooks`'.
@usableFromInline enum ClearPicture {
    @usableFromInline static func png(_ size: Size) -> Data? {
        let (width, height) = (Int(size.width), Int(size.height))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage()
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
