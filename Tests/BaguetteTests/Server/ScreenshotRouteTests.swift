import CoreGraphics
import Foundation
import ImageIO
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Handler-level tests for the sized screenshot routes.
///
/// Same split as `BezelRoutesTests`: we drive the *internal* helpers
/// that turn a query string into a `CaptureOptions`, re-encode a
/// captured framebuffer onto the canvas the user asked for, and
/// composite the DeviceKit bezel around it — never the Hummingbird
/// `Response` builders that wrap them. No booted simulator is needed;
/// the "framebuffer" is a solid-colour bitmap this suite renders.
@Suite("Server sized screenshot routes")
struct ScreenshotRouteTests {

    // MARK: - ?size= / ?fit= / ?background=

    @Test func `should capture the native framebuffer, contained on a white mat, when no knobs are set`() throws {
        let options = try Server.captureOptions(size: nil, fit: nil, background: nil)

        #expect(options.size == CaptureSize.native)
        #expect(options.fit == .contain)
        #expect(options.background == .color("#ffffff"))
    }

    @Test func `should size a screenshot to an App Store preset by the name the picker shows`() throws {
        let options = try Server.captureOptions(
            size: "appstore-6.9", fit: "cover", background: "transparent"
        )

        #expect(options.size.kind == .fixed(RenderDimensions(width: 1290, height: 2796)))
        #expect(options.fit == .cover)
        #expect(options.background == .transparent)
    }

    @Test func `should reject an unknown screenshot size rather than fall back to native`() {
        #expect(throws: Server.CaptureQueryError.unknownSize("nonsense")) {
            _ = try Server.captureOptions(size: "nonsense", fit: nil, background: nil)
        }
        #expect(
            Server.CaptureQueryError.unknownSize("nonsense").message
                == CaptureSizeError.unknownSize("nonsense").message
        )
    }

    @Test func `should reject an unknown screenshot fit and list the known ones`() {
        #expect(throws: Server.CaptureQueryError.unknownFit("squish")) {
            _ = try Server.captureOptions(size: "square", fit: "squish", background: nil)
        }
        #expect(
            Server.CaptureQueryError.unknownFit("squish").message.contains("contain")
        )
    }

    @Test func `should accept a hex background with or without its hash`() throws {
        let bare = try Server.captureOptions(size: nil, fit: nil, background: "ff8800")
        let hashed = try Server.captureOptions(size: nil, fit: nil, background: "#ff8800")

        #expect(bare.background == .color("#ff8800"))
        #expect(hashed.background == .color("#ff8800"))
    }

    @Test func `should reject a screenshot background that isn't a colour`() {
        #expect(throws: Server.CaptureQueryError.unknownBackground("chartreuse")) {
            _ = try Server.captureOptions(size: nil, fit: nil, background: "chartreuse")
        }
    }

    // MARK: - re-encoding the framebuffer

    @Test func `should hand back the captured bytes untouched for a native jpeg screenshot`() throws {
        let captured = Self.solid(width: 100, height: 200, rgb: (1, 0, 0), format: .jpeg)

        let outcome = Server.recapture(
            captured, sourceFormat: .jpeg, format: .jpeg,
            options: .default, quality: 0.85
        )

        #expect(outcome == .unchanged)
    }

    @Test func `should come out at exactly the submission pixel size for an App Store preset`() throws {
        let captured = Self.solid(width: 100, height: 200, rgb: (1, 0, 0), format: .jpeg)
        let options = try Server.captureOptions(size: "appstore-6.9", fit: nil, background: nil)

        let bytes = try #require(Self.encoded(Server.recapture(
            captured, sourceFormat: .jpeg, format: .png,
            options: options, quality: 0.85
        )))

        #expect(Self.dimensions(bytes) == RenderDimensions(width: 1290, height: 2796))
    }

    @Test func `should grow a square canvas so the whole frame fits, matted on the background`() throws {
        let captured = Self.solid(width: 100, height: 200, rgb: (1, 0, 0), format: .png)
        let options = try Server.captureOptions(size: "square", fit: "contain", background: "00ff00")

        let bytes = try #require(Self.encoded(Server.recapture(
            captured, sourceFormat: .png, format: .png,
            options: options, quality: 0.85
        )))

        #expect(Self.dimensions(bytes) == RenderDimensions(width: 200, height: 200))
        // The tall frame is centred, so the top-left corner is mat.
        let corner = Self.pixel(bytes, x: 0, y: 0)
        #expect(corner[0] < 40 && corner[1] > 200 && corner[2] < 40)
    }

    @Test func `should fill the square and crop the overflow when the fit is cover`() throws {
        let captured = Self.solid(width: 100, height: 200, rgb: (1, 0, 0), format: .png)
        let options = try Server.captureOptions(size: "square", fit: "cover", background: "00ff00")

        let bytes = try #require(Self.encoded(Server.recapture(
            captured, sourceFormat: .png, format: .png,
            options: options, quality: 0.85
        )))

        #expect(Self.dimensions(bytes) == RenderDimensions(width: 200, height: 200))
        // Nothing is matted — the frame is scaled up until it covers.
        let corner = Self.pixel(bytes, x: 0, y: 0)
        #expect(corner[0] > 200 && corner[1] < 40 && corner[2] < 40)
    }

    @Test func `should re-encode the captured jpeg as png for a png screenshot`() throws {
        let captured = Self.solid(width: 100, height: 200, rgb: (1, 0, 0), format: .jpeg)

        let bytes = try #require(Self.encoded(Server.recapture(
            captured, sourceFormat: .jpeg, format: .png,
            options: .default, quality: 0.85
        )))

        #expect(bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        #expect(Self.dimensions(bytes) == RenderDimensions(width: 100, height: 200))
    }

    @Test func `should label each screenshot extension with the content type browsers decode by`() {
        #expect(Server.CaptureImageFormat.jpeg.contentType == "image/jpeg")
        #expect(Server.CaptureImageFormat.png.contentType == "image/png")
    }

    @Test func `should capture a png screenshot at full quality and a jpeg at the default`() {
        // `ScreenSnapshot` only speaks JPEG, so a PNG still is a JPEG
        // round-trip whether the caller wanted one or not. Capturing
        // at 1.0 keeps that intermediate from showing up as ringing
        // in something the extension promises is lossless.
        #expect(Server.CaptureImageFormat.jpeg.defaultQuality == 0.85)
        #expect(Server.CaptureImageFormat.png.defaultQuality == 1.0)
    }

    @Test func `should mat a transparent background white when the screenshot is jpeg`() throws {
        let captured = Self.solid(width: 100, height: 200, rgb: (1, 0, 0), format: .png)
        let options = try Server.captureOptions(
            size: "square", fit: "contain", background: "transparent"
        )

        let bytes = try #require(Self.encoded(Server.recapture(
            captured, sourceFormat: .png, format: .jpeg,
            options: options, quality: 1
        )))

        // Left un-matted the alpha would flatten to black on encode.
        let corner = Self.pixel(bytes, x: 0, y: 0)
        #expect(corner[0] > 240 && corner[1] > 240 && corner[2] > 240)
    }

    @Test func `should fail rather than serve zero bytes when the framebuffer is unreadable`() {
        let outcome = Server.recapture(
            Data("not an image".utf8), sourceFormat: .jpeg, format: .png,
            options: .default, quality: 0.85
        )
        #expect(outcome == .failed)
    }

    // MARK: - bezel composite

    @Test func `should drop the framebuffer into the chrome's screen cutout with buttons`() throws {
        let assets = Self.chromeAssets()
        let placement = Server.bezelPlacement(assets: assets, withButtons: true)

        #expect(placement.bezel.size == Size(width: 120, height: 200))
        #expect(placement.screen == Rect(
            origin: Point(x: 20, y: 10),
            size: Size(width: 80, height: 180)
        ))
        // outerCornerRadius 20 minus one bezel width (10).
        #expect(placement.cornerRadius == 10)
    }

    @Test func `should drop the button overshoot from the canvas for a bare bezel`() throws {
        let assets = Self.chromeAssets()
        let placement = Server.bezelPlacement(assets: assets, withButtons: false)

        #expect(placement.bezel.size == Size(width: 100, height: 200))
        #expect(placement.screen == Rect(
            origin: Point(x: 10, y: 10),
            size: Size(width: 80, height: 180)
        ))
    }

    @Test func `should size a bezel screenshot to the chrome's own composite by default`() throws {
        let bytes = try #require(Server.bezelCapture(
            screenImage: Self.solid(width: 80, height: 180, rgb: (1, 0, 0), format: .jpeg),
            assets: Self.chromeAssets(),
            withButtons: true,
            options: .default
        ))

        #expect(Self.dimensions(bytes) == RenderDimensions(width: 120, height: 200))
        // The screen sits ON TOP of the bezel's opaque off-glass.
        let centre = Self.pixel(bytes, x: 60, y: 100)
        #expect(centre[0] > 200 && centre[1] < 40 && centre[2] < 40)
    }

    @Test func `should keep the framebuffer at its captured resolution in a bezel screenshot`() throws {
        // Chrome geometry is 1× points; the framebuffer is device
        // pixels. Sizing the composite off the chrome would throw ~3×
        // of a real phone's capture away before `?size=` ever upscales
        // it back — exactly the App Store case this route is for.
        let bytes = try #require(Server.bezelCapture(
            screenImage: Self.solid(width: 240, height: 540, rgb: (1, 0, 0), format: .png),
            assets: Self.chromeAssets(),
            withButtons: true,
            options: .default
        ))

        // 240 px into an 80 pt cutout is 3×, so the 120 × 200 pt
        // chrome comes out at 360 × 600.
        #expect(Self.dimensions(bytes) == RenderDimensions(width: 360, height: 600))
    }

    @Test func `should never shrink the bezel below its own resolution when the framebuffer is small`() throws {
        // A framebuffer smaller than the cutout (a heavy `?scale=`)
        // must not shrink the bezel with it — the chrome is already
        // at its authored size.
        let bytes = try #require(Server.bezelCapture(
            screenImage: Self.solid(width: 40, height: 90, rgb: (1, 0, 0), format: .png),
            assets: Self.chromeAssets(),
            withButtons: true,
            options: .default
        ))

        #expect(Self.dimensions(bytes) == RenderDimensions(width: 120, height: 200))
    }

    @Test func `should size a bezel screenshot with the same size vocabulary as a bare one`() throws {
        let options = try Server.captureOptions(size: "appstore-6.9", fit: nil, background: nil)
        let bytes = try #require(Server.bezelCapture(
            screenImage: Self.solid(width: 80, height: 180, rgb: (1, 0, 0), format: .jpeg),
            assets: Self.chromeAssets(),
            withButtons: true,
            options: options
        ))

        #expect(Self.dimensions(bytes) == RenderDimensions(width: 1290, height: 2796))
    }

    @Test func `should fail a bezel screenshot when the framebuffer can't be decoded`() {
        #expect(Server.bezelCapture(
            screenImage: Data("not an image".utf8),
            assets: Self.chromeAssets(),
            withButtons: true,
            options: .default
        ) == nil)
    }
}

// MARK: - fixtures

private extension ScreenshotRouteTests {

    /// A chrome whose merged composite is 10px wider on each side than
    /// the bare device body — the button overshoot — with a 10px bezel
    /// carved around an 80 × 180 screen.
    static func chromeAssets() -> DeviceChromeAssets {
        let chrome = DeviceChrome(
            identifier: "phone-test",
            screenInsets: Insets(top: 10, left: 10, bottom: 10, right: 10),
            outerCornerRadius: 20,
            buttons: [],
            compositeImageName: "PhoneComposite",
            devicePadding: Insets(top: 0, left: 10, bottom: 0, right: 10)
        )
        return DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: solid(width: 120, height: 200, rgb: (0, 0, 0), format: .png),
                size: Size(width: 120, height: 200)
            ),
            bareComposite: ChromeImage(
                data: solid(width: 100, height: 200, rgb: (0, 0, 0), format: .png),
                size: Size(width: 100, height: 200)
            ),
            buttonImages: [:],
            buttonMargins: Insets(top: 0, left: 10, bottom: 0, right: 10)
        )
    }

    static func encoded(_ outcome: Server.CaptureOutcome) -> Data? {
        if case .encoded(let data) = outcome { return data }
        return nil
    }

    static func solid(
        width: Int, height: Int,
        rgb: (Double, Double, Double),
        format: Server.CaptureImageFormat
    ) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            out, format.utType as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func dimensions(_ data: Data) -> RenderDimensions? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return RenderDimensions(width: width, height: height)
    }

    /// RGBA of one pixel, addressed top-left-origin like the rest of
    /// the chrome geometry (CoreGraphics is bottom-up).
    static func pixel(_ data: Data, x: Int, y: Int) -> [UInt8] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: CGFloat(-x), y: CGFloat(-(image.height - 1 - y)))
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }
        return bytes
    }
}
