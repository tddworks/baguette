import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One-shot window capture for the macOS path.
///
/// `ScreenSnapshot.capture(screen:)` works great on iOS simulators
/// (`SimulatorKitScreen` delivers frames immediately), but on macOS
/// `SCStream` only fires its sample handler when window contents
/// change — an idle TextEdit window with a static document never
/// produces a frame, so the 2 s timeout fires and the route 500s.
///
/// `SCScreenshotManager.captureImage(contentFilter:configuration:)`
/// is the API that exists for exactly this case: it returns one
/// image synchronously (well, async-but-not-callback-driven) without
/// running a stream. macOS 14+. Used by both
/// `baguette mac screenshot` and `GET /mac/<bundleID>/screen.jpg`.
///
/// Streaming (`WS /mac/<bundleID>/stream`) keeps using `SCStream`
/// since that's where the live-update behaviour pays off.
enum MacScreenshotter {

    /// Capture the frontmost window of the target app, encoded as
    /// JPEG. Throws `MacAppError.notFound` when the app has no
    /// on-screen window, and `ScreenSnapshot.Failure.encodeFailed`
    /// when ImageIO refuses to write the JPEG.
    static func capture(
        pid: pid_t,
        quality: Double = 0.85,
        scale: Int = 1
    ) async throws -> Data {
        // 1. Find the target app's primary window. `SCShareableContent`
        //    lists every window of the PID — including drag-proxy
        //    "Window" (~66×20) that AppKit creates while the user
        //    mouse-drags. Picking `.first` lands us on that proxy
        //    instead of the document. Pick the largest by area so
        //    the document window wins, regardless of z-order.
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        guard let window = content.windows
            .filter({ $0.owningApplication?.processID == pid })
            .max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })
        else {
            throw MacAppError.notFound(bundleID: "pid:\(pid)")
        }

        // 2. Configure the capture. Multiply by 2 for retina, then
        //    divide by `scale` so `?scale=2` halves both dimensions
        //    (matching the iOS `ScreenSnapshot.capture` semantics).
        let s = max(1, scale)
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(window.frame.width * 2) / s)
        cfg.height = max(1, Int(window.frame.height * 2) / s)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false

        // 3. One-shot capture. `SCScreenshotManager.captureImage` is
        //    the macOS-14+ API designed for exactly this use case.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg
        )

        // 4. JPEG-encode via ImageIO. Same path the iOS `JPEGEncoder`
        //    uses; we re-implement here because the iOS encoder
        //    expects an `IOSurface`, not a `CGImage`.
        return try jpegEncode(cgImage, quality: quality)
    }

    private static func jpegEncode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ScreenSnapshot.Failure.encodeFailed
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenSnapshot.Failure.encodeFailed
        }
        return data as Data
    }
}
