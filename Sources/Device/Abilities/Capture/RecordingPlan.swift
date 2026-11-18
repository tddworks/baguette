import Foundation

/// Everything the user asked `baguette record` for, as one value: how
/// big the video comes out, how the simulator's frame sits inside that,
/// what shows through the letterbox, how fast, how long, and which
/// container.
///
/// Size / fit / background are the shared `Device/Abilities/Capture` vocabulary —
/// `--size appstore-6.9` on a recording means the same pixels as
/// `--size appstore-6.9` on a screenshot or as `?size=appstore-6.9` on
/// the HTTP routes. See `docs/features/capture-size/README.md`.
///
/// The plan is resolved against the *source* — the simulator's own frame
/// size, which isn't known until the first surface arrives — so nothing
/// here is decided at parse time beyond what the user typed.
public struct RecordingPlan: Equatable, Sendable {
    /// Frame rates outside this range aren't recordable: 0 divides by
    /// zero in the cadence, and VideoToolbox has no use for 240.
    public static let frameRateRange = 1...120

    public let size: CaptureSize
    public let fit: CaptureFit
    /// What shows through under `contain`. Video has no alpha channel,
    /// so unlike a PNG screenshot there is always *some* mat colour.
    public let background: HexColor
    public let fps: Int
    public let bitrateBps: Int
    /// `nil` records until the user stops it (SIGINT).
    public let duration: Double?
    public let format: RecordingFormat

    public init(
        size: CaptureSize,
        fit: CaptureFit,
        background: HexColor,
        fps: Int,
        bitrateBps: Int,
        duration: Double?,
        format: RecordingFormat
    ) {
        self.size = size
        self.fit = fit
        self.background = background
        self.fps = min(max(fps, Self.frameRateRange.lowerBound), Self.frameRateRange.upperBound)
        self.bitrateBps = max(1, bitrateBps)
        self.duration = duration
        self.format = format
    }

    /// Seconds a single frame occupies — the tail the written file gets
    /// past its last frame.
    public var frameInterval: Double {
        1.0 / Double(fps)
    }

    /// Where the simulator's frame lands inside the video canvas.
    ///
    /// This is `CaptureSize.plan` plus one recording-only correction:
    /// H.264 encodes 4:2:0 chroma, so both axes of the canvas must be
    /// even. An odd canvas is grown by a pixel — grown, never cropped,
    /// so nothing the user asked to see is thrown away.
    ///
    /// Who absorbs that pixel depends on the fit, because the fits
    /// promise different things. `contain` promises the whole frame is
    /// visible, so the extra pixel becomes one more row of mat and the
    /// frame keeps its own pixels. `cover` and `stretch` promise no mat
    /// at all, so the draw rect grows with the canvas and keeps that
    /// promise. `native` is pixel-exactness above all, so it takes the
    /// mat too rather than resample a whole frame for one pixel.
    public func placement(source: RenderDimensions) -> CapturePlacement {
        let raw = size.plan(source: source, fit: fit)
        let even = VideoFrameDimensions(
            requested: RenderDimensions(width: raw.width, height: raw.height)
        )
        let growX = even.width - raw.width
        let growY = even.height - raw.height
        guard growX != 0 || growY != 0 else { return raw }

        let fillsCanvas = !size.isNative && (fit == .cover || fit == .stretch)
        return CapturePlacement(
            width: even.width,
            height: even.height,
            drawX: raw.drawX,
            drawY: raw.drawY,
            drawWidth: raw.drawWidth + (fillsCanvas ? growX : 0),
            drawHeight: raw.drawHeight + (fillsCanvas ? growY : 0)
        )
    }
}
