import BaguetteDevice
import Foundation

/// Pure geometry: shrink a frame so both edges fit within a square
/// `max × max` box while preserving aspect ratio. **Downscale only** —
/// a frame already inside the box passes through untouched (we never
/// upscale a small source into a blurry big one).
///
/// This is the step the webcam path never needs: `HostVideoCapture`
/// bounds resolution with the capture session's `videoSettings`, but a
/// still image or a video file arrives at its native size (often 1080p
/// or larger). `CameraFrame.init` rejects anything past
/// `SharedFrameLayout.maxCanvasWidth/Height` (1280), so an unfitted
/// frame would be dropped wholesale — every file source must fit first.
enum ScaleToFit {

    /// Target dimensions after fitting `width × height` into `max × max`.
    /// Both results are ≥ 1 (a rounded-to-zero edge is clamped up).
    static func fit(width: Int, height: Int, max: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, max > 0 else { return (1, 1) }
        let scale = Swift.min(
            1.0,
            Double(max) / Double(width),
            Double(max) / Double(height)
        )
        let w = Swift.max(1, Int((Double(width) * scale).rounded()))
        let h = Swift.max(1, Int((Double(height) * scale).rounded()))
        return (w, h)
    }
}
