import CoreVideo
import Foundation
import IOSurface
import Mockable

/// A hardware H.264 decompression session — VideoToolbox's
/// `VTDecompressionSession`, reduced to the calls a decoder makes. It
/// decides nothing: whether to crop, which frames to decode and which
/// pictures to hand on belong to `VTH264Decoder` and `VTStreamDecoder`.
/// The real one is `VideoToolboxDecompressionSession`.
@Mockable
protocol DecompressionSession: AnyObject, Sendable {
    /// The coded size of the pictures these parameter sets describe.
    func picture(parameterSets: [Data], nalUnitHeaderLength: Int) -> Result<Size, DecompressionRefusal>
    /// Open a session for these parameter sets, its BGRA pictures cropped to
    /// `aperture` when there is one. The open session is replaced only once
    /// the new one opens; nil means it did.
    func open(parameterSets: [Data], nalUnitHeaderLength: Int, croppedTo aperture: CleanAperture?) -> DecompressionRefusal?
    /// Decode one frame of length-prefixed NAL units. `done` is called at
    /// most once — before this returns, or later on the session's own
    /// thread when `asynchronously`. Nothing is called without a session.
    func decode(_ frame: Data, asynchronously: Bool, done: @escaping @Sendable (DecompressionResult) -> Void)
    /// Finish the frames in flight, then close the session.
    func close()
}

/// Why VideoToolbox would not decode a stream, with its status.
enum DecompressionRefusal: Error, Equatable, Sendable {
    /// The parameter sets describe no picture it can decode.
    case format(Int32)
    /// It would not open a session for them.
    case session(Int32)
}

/// What the session made of one frame: its status, and the decoded picture.
struct DecompressionResult: @unchecked Sendable {
    let status: Int32
    let picture: CVPixelBuffer?

    /// The surface under a decoded picture — nil for a failed frame or a
    /// picture not backed by one.
    var surface: IOSurface? {
        guard status == 0, let picture, let surface = CVPixelBufferGetIOSurface(picture)?.takeUnretainedValue()
        else { return nil }
        return unsafeDowncast(surface, to: IOSurface.self)
    }
}
