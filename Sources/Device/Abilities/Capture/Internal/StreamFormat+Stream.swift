import Foundation

/// The encoder each wire format is built with. Here, beside the encoders,
/// so the Domain names a format without building anything outside itself.
public extension StreamFormat {
    /// Build the `Stream` impl for this format. Caller doesn't switch on
    /// the format — adding a new wire format means adding a new `Stream`
    /// type and a new case here, never editing call sites.
    /// `codec`: what a video format encodes in (H.264 unless asked otherwise); MJPEG has none.
    func makeStream(config: StreamConfig, sink: any FrameSink, quality: Double, codec: any Codec = H264Codec()) -> any Stream {
        switch self {
        case .mjpeg: return MJPEGStream(config: config, sink: sink, quality: quality)
        case .avcc:  return AVCCStream(config: config, sink: sink, quality: quality, codec: codec)
        }
    }
}
