import Foundation

/// One frame handed back by a `VideoDecoder`, already fitted to the
/// shared canvas and copied out of its `CVPixelBuffer` so it survives
/// past the decode call (unlike the webcam path's `RawBGRAFrame`, whose
/// base address is valid only during the callback). Tightly-packed BGRA
/// — `pixels.count == width * height * 4`. `presentationMs` is the
/// frame's timestamp within the asset, which the orchestrator uses to
/// pace playback.
public struct DecodedVideoFrame: Equatable, Sendable {
    public let pixels: Data
    public let width: UInt32
    public let height: UInt32
    public let presentationMs: UInt32

    /// Project a decoder's timestamp — seconds within the asset — onto
    /// this frame's millisecond clock.
    ///
    /// A malformed asset reports an invalid or indefinite timestamp,
    /// which reaches us as a non-finite number of seconds, and a
    /// corrupt one can report a finite value far past what the clock
    /// holds. `UInt32.init(_: Double)` traps on both, which would take
    /// the whole server down for one bad upload — so saturate instead
    /// of trusting the file. Non-finite reads as "start of asset": a
    /// frame we can't place is better paced immediately than deferred.
    public static func presentationMs(seconds: Double) -> UInt32 {
        let ms = seconds * 1000
        // NaN has to go first: it compares false against everything, so
        // it would fall straight through `min`/`max` and trap below.
        guard ms.isFinite else { return 0 }
        return UInt32(min(max(ms, 0), Double(UInt32.max)))
    }

    /// Project into a `CameraFrame` under an orchestrator-assigned
    /// sequence. Throws if the pixels don't match the dimensions
    /// (delegates to `CameraFrame`'s validation).
    public func frame(sequence: UInt32) throws -> CameraFrame {
        try CameraFrame(
            sequence: sequence,
            timestampMs: presentationMs,
            width: width,
            height: height,
            pixels: pixels
        )
    }

    public init(pixels: Data, width: UInt32, height: UInt32, presentationMs: UInt32) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.presentationMs = presentationMs
    }
}
