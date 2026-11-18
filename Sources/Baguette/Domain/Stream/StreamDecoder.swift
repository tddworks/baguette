import Foundation
import IOSurface
import Mockable

/// A live H.264 decoder configured straight from a stream's SPS and PPS. Encoded frames fed to
/// `decode` land on `onFrame` as IOSurfaces for the stream pipeline. The
/// concrete impl wraps `VTDecompressionSession` and is integration-only.
@Mockable
protocol StreamDecoder: AnyObject, Sendable {
    /// Build (or rebuild) the session for these parameter sets.
    func configure(parameterSets: [Data], onFrame: @escaping @Sendable (IOSurface) -> Void) throws
    /// Feed one frame of four-byte length-prefixed NAL units.
    func decode(_ frame: Data)
    /// Invalidate the session and stop delivering frames.
    func stop()
}
