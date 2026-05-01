import Foundation

/// The wire format the user picks for a frame stream. Drives the codec
/// choice and the byte envelope downstream consumers parse.
enum StreamFormat: String, Sendable, Equatable {
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

    /// Build the `Stream` impl for this format. Caller doesn't switch on
    /// the format — adding a new wire format means adding a new `Stream`
    /// type and a new case here, never editing call sites.
    func makeStream(config: StreamConfig, sink: any FrameSink, quality: Double) -> any Stream {
        switch self {
        case .mjpeg: return MJPEGStream(config: config, sink: sink, quality: quality)
        case .avcc:  return AVCCStream(config: config, sink: sink, quality: quality)
        }
    }
}
