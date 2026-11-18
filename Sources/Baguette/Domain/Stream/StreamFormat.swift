import BaguetteDevice
import Foundation

/// The wire format the user picks for a frame stream. Drives the codec
/// choice and the byte envelope downstream consumers parse.
enum StreamFormat: String, Sendable, Equatable, CaseIterable {
    /// Stateless JPEG-per-frame inside a multipart HTTP envelope. Easy for
    /// browsers; high bandwidth.
    case mjpeg
    /// AVCC framing — H.264 NALs (length-prefixed) preceded by a JPEG seed
    /// for instant first paint before the first IDR arrives.
    case avcc

    /// MJPEG can drop frames with identical pixels — the decoder is
    /// stateless so a missing frame just means "show the last one." AVCC
    /// carries P-frames that depend on previous frames; dropping any of
    /// them corrupts the decoder state.
    var skipsUnchangedFrames: Bool { self == .mjpeg }
}
