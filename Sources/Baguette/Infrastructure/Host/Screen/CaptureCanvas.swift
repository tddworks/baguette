import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import IOSurface

/// The CoreGraphics half of the capture-size vocabulary.
///
/// `CaptureSize` decides *where* a frame lands — canvas size, draw rect,
/// crop overflow. `CaptureCanvas` is the part that actually moves the
/// pixels: fill the background, draw the frame into the placement's
/// rect, hand back a `CGImage`, and encode it as PNG or JPEG. Splitting
/// it out this way is what makes the size feature testable — synthetic
/// `CGImage`s go in, assertable pixels come out, and the only thing left
/// in `ScreenSnapshot` that needs a live device is the `Screen`'s
/// frame callback itself.
///
/// The one non-obvious bit is the vertical flip in `compose`. A
/// `CapturePlacement` counts `drawY` **down from the top** — the same
/// convention the browser-side `CaptureComposer` uses, because that's how
/// a canvas 2D context talks. CoreGraphics counts **up from the bottom**,
/// so the draw rect's origin has to be mirrored. Skipping that is
/// invisible on a symmetric letterbox and quietly wrong on every
/// odd-pixel or `cover` crop.
enum CaptureCanvas {

    // MARK: - Background

    /// `transparent` (or an empty string) means "no background at all" —
    /// the canvas keeps its zeroed alpha. Anything else is a `#RRGGBB`
    /// colour. The `#` is optional here so a URL query that dropped it
    /// (`?background=101010`, since `#` starts a fragment) still parses;
    /// `HexColor` unconditionally drops the first character, so it must
    /// be handed a prefixed string.
    static func background(_ spec: String) -> HexColor? {
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, text != "transparent", text != "none" else { return nil }
        return HexColor(text.hasPrefix("#") ? text : "#" + text)
    }

    // MARK: - Composition

    /// Re-lay `source` onto the canvas `size` asks for. Returns the very
    /// same image when there is nothing to do, so a `native` capture is
    /// never resampled.
    static func apply(
        size: CaptureSize,
        fit: CaptureFit,
        background: String,
        to source: CGImage
    ) -> CGImage? {
        let dimensions = RenderDimensions(width: source.width, height: source.height)
        return compose(
            source,
            placement: size.plan(source: dimensions, fit: fit),
            background: self.background(background)
        )
    }

    /// Draw `source` into `placement` on a fresh canvas. A `nil`
    /// background leaves the uncovered area transparent.
    static func compose(
        _ source: CGImage,
        placement: CapturePlacement,
        background: HexColor?
    ) -> CGImage? {
        let dimensions = RenderDimensions(width: source.width, height: source.height)
        if placement.isIdentity(for: dimensions) { return source }
        guard placement.width > 0, placement.height > 0,
              placement.drawWidth > 0, placement.drawHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: placement.width, height: placement.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        if let background {
            context.setFillColor(
                red: background.red, green: background.green,
                blue: background.blue, alpha: 1
            )
            context.fill(CGRect(x: 0, y: 0, width: placement.width, height: placement.height))
        }

        context.interpolationQuality = .high
        // Placement counts y down from the top; CoreGraphics counts up.
        let originY = placement.height - placement.drawY - placement.drawHeight
        context.draw(source, in: CGRect(
            x: placement.drawX, y: originY,
            width: placement.drawWidth, height: placement.drawHeight
        ))
        return context.makeImage()
    }

    // MARK: - Lifting a framebuffer to a CGImage

    /// Wrap a framebuffer surface zero-copy and lift it to a `CGImage`.
    static func image(from surface: IOSurface) -> CGImage? {
        var buffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer = buffer?.takeRetainedValue() else { return nil }
        return image(from: pixelBuffer)
    }

    /// Lift a BGRA pixel buffer (a raw framebuffer, or one
    /// `VideoFrameScaler` produced) to a `CGImage` that **owns its
    /// bytes**.
    ///
    /// The copy is the point. A `Screen` may keep rendering into the
    /// surface it handed us — `screen.stop()` only lands after the
    /// capture returns — so an image still aliasing that memory would be
    /// composed and encoded out from under a live writer, and come out a
    /// torn mix of two frames. `CGBitmapContextCreateImage` only promises
    /// copy-on-write against drawing *through the context*; it can't see
    /// a foreign writer. So the bytes are copied here, under the lock,
    /// and handed to a provider that retains them.
    static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, stride >= width * 4 else { return nil }

        let pixels = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }

        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Encoding

    /// Encode to the requested container. `quality` only reaches JPEG —
    /// PNG is lossless, and `kCGImageDestinationLossyCompressionQuality`
    /// is meaningless there.
    static func encode(_ image: CGImage, format: CaptureFormat, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, format.contentType as CFString, 1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// The container a capture is written in. JPEG is the historical default
/// — every `<img src="…/screenshot.jpg">` and every `curl -o shot.jpg`
/// already expects it — and PNG is what a marketing capture with a
/// transparent letterbox actually needs, since JPEG has no alpha channel
/// and flattens the bars to black.
enum CaptureFormat: String, Equatable, Sendable, CaseIterable {
    case jpeg
    case png

    /// `jpg` and `jpeg` are the same thing to a user; both parse.
    init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespaces).lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        default: return nil
        }
    }

    /// What a file of this format is called on disk.
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    var contentType: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        }
    }

    /// One line for `--help`.
    static var list: String { "png | jpg" }

    /// What the user named wins; otherwise the output path's extension
    /// decides, so `-o shot.png` never quietly writes JPEG bytes into a
    /// `.png` file. Stdout and anything unrecognised stay JPEG.
    static func resolve(explicit: CaptureFormat?, output: String?) -> CaptureFormat {
        if let explicit { return explicit }
        guard let output else { return .jpeg }
        let ext = (output as NSString).pathExtension.lowercased()
        return CaptureFormat(argument: ext) ?? .jpeg
    }
}
