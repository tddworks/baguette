import BaguetteDevice
import Foundation

/// The picture a Mac display is captured at: its pixels, scaled down until its
/// long side fits the hardware H.264 encoder (4096) — a 5K or 6K display would
/// otherwise be refused by the encoder. ScreenCaptureKit scales at the source,
/// so nothing larger is ever copied. Both sides stay even, as 4:2:0 needs.
struct DisplayCaptureSize: Equatable, Sendable {
    /// The longest side the encoder takes.
    static let longestSide: Double = 4096

    let pixels: Size

    init(points: Size, pixelsPerPoint: Double) {
        let width = points.width * pixelsPerPoint
        let height = points.height * pixelsPerPoint
        let fit = min(1, Self.longestSide / max(width, height))
        pixels = Size(width: Self.even(width * fit), height: Self.even(height * fit))
    }

    private static func even(_ side: Double) -> Double {
        (side / 2).rounded(.down) * 2
    }
}
