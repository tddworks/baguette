import CoreGraphics
import Foundation
import IOSurface

/// One-shot frame capture: open `Screen`, wait for the first IOSurface
/// the screen delivers, lay it onto the requested canvas, encode, stop.
/// Shared by the `baguette screenshot` CLI and the
/// `GET /simulators/:udid/screenshot.jpg` HTTP route. A timeout
/// guards against an idle / wedged simulator that never fires its frame
/// callback.
enum ScreenSnapshot {

    struct Frame: Sendable {
        let bytes: Data
        let geometry: CaptureGeometry
    }

    enum Failure: Error, Equatable {
        case timeout
        case encodeFailed
    }

    /// Capture one frame.
    ///
    /// `scale ≥ 2` routes through `VideoFrameScaler` so the encoded bytes
    /// are smaller; `size` / `fit` / `background` are the shared
    /// capture-size vocabulary (see `docs/features/capture-size/README.md`), and
    /// every one of them defaults to "exactly what the framebuffer gave
    /// us" so the historical call sites keep their historical bytes.
    static func capture(
        screen: any Screen,
        quality: Double = 0.85,
        scale: Int = 1,
        timeout: TimeInterval = 2.0,
        size: CaptureSize = .native,
        fit: CaptureFit = .contain,
        background: String = "transparent",
        format: CaptureFormat = .jpeg
    ) async throws -> Data {
        try await captureWithGeometry(
            screen: screen, quality: quality, scale: scale, timeout: timeout,
            size: size, fit: fit, background: background, format: format
        ).bytes
    }

    /// Geometry and encoded bytes come from the same delivered surface
    /// and the same placement; no second query can race a display change.
    static func captureWithGeometry(
        screen: any Screen,
        quality: Double = 0.85,
        scale: Int = 1,
        timeout: TimeInterval = 2.0,
        size: CaptureSize = .native,
        fit: CaptureFit = .contain,
        background: String = "transparent",
        format: CaptureFormat = .jpeg
    ) async throws -> Frame {
        let session = SnapshotSession(
            quality: quality, scale: scale,
            size: size, fit: fit, background: background, format: format
        )

        defer { screen.stop() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Frame, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard session.claim() else { return }
                cont.resume(throwing: Failure.timeout)
            }
            timer.resume()

            do {
                try screen.start { surface in
                    guard session.claim() else { return }
                    timer.cancel()
                    if let frame = session.encode(surface) {
                        cont.resume(returning: frame)
                    } else {
                        cont.resume(throwing: Failure.encodeFailed)
                    }
                }
            } catch {
                guard session.claim() else { return }
                timer.cancel()
                cont.resume(throwing: error)
            }
        }
    }
}

/// Owns the per-capture frame scaler, the chosen output shape, and the
/// single-shot guard. `VideoFrameScaler` is a class without `Sendable`,
/// so wrapping it in an `@unchecked Sendable` holder lets the
/// screen-callback closure capture it without tripping strict
/// concurrency. Safe because each `capture(...)` call instantiates its
/// own session and `encode` runs at most once.
private final class SnapshotSession: @unchecked Sendable {
    private let quality: Double
    private let scaler: VideoFrameScaler?
    private let scale: Int
    private let size: CaptureSize
    private let fit: CaptureFit
    private let background: String
    private let format: CaptureFormat
    private let lock = NSLock()
    private var taken = false

    init(
        quality: Double, scale: Int,
        size: CaptureSize, fit: CaptureFit, background: String, format: CaptureFormat
    ) {
        self.quality = quality
        self.scaler = scale > 1 ? VideoFrameScaler() : nil
        self.scale = scale
        self.size = size
        self.fit = fit
        self.background = background
        self.format = format
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }

    /// Downscale (if asked), lift to a `CGImage`, re-lay onto the
    /// requested canvas, encode. The identity placement keeps native
    /// captures on the historical path without another resampling.
    func encode(_ surface: IOSurface) -> ScreenSnapshot.Frame? {
        let lifted: CGImage?
        if let scaler {
            guard let scaled = scaler.scale(surface, by: scale) else { return nil }
            lifted = CaptureCanvas.image(from: scaled)
        } else {
            lifted = CaptureCanvas.image(from: surface)
        }
        guard let lifted else { return nil }
        let scaledPixels = RenderDimensions(width: lifted.width, height: lifted.height)
        let placement = size.plan(source: scaledPixels, fit: fit)
        guard
            let composed = CaptureCanvas.compose(
                lifted, placement: placement, background: CaptureCanvas.background(background)
            ), let bytes = CaptureCanvas.encode(composed, format: format, quality: quality)
        else { return nil }
        return ScreenSnapshot.Frame(
            bytes: bytes,
            geometry: CaptureGeometry(
                framebufferPixels: RenderDimensions(
                    width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface)
                ),
                scaledPixels: scaledPixels,
                placement: placement
            )
        )
    }
}
