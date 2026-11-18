import Foundation
import IOSurface
import Mockable

/// A live H.264 decoder — the conversational collaborator on the
/// device-twin video path. `configure` builds (or rebuilds) the
/// decompression session from an avcC parameter-set blob; encoded
/// frames fed to `decode` land on `onFrame` as IOSurfaces, ready for
/// the same stream pipeline every other `Screen` feeds. The concrete
/// impl wraps `VTDecompressionSession` and is integration-only; tests
/// inject `MockH264Decoder`.
@Mockable
protocol H264Decoder: AnyObject, Sendable {
    /// Build the session from the stream's avcC description. Called
    /// again whenever the companion re-sends parameter sets (e.g. after
    /// a bitrate or dimension change).
    func configure(description: Data, onFrame: @escaping @Sendable (IOSurface) -> Void) throws

    /// Feed one AVCC-length-prefixed encoded frame (key or delta).
    func decode(_ frame: Data)

    /// Invalidate the session and stop delivering frames.
    func stop()
}
