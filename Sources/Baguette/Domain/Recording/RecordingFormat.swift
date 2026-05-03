import Foundation

/// Container format the recorder muxes encoded frames into. Today MP4 is
/// the only choice because the AVCC stream produces H.264 NALUs that
/// `ffmpeg -c copy` writes straight to MP4 without re-encoding — no other
/// container is reachable from the existing pipeline.
enum RecordingFormat: String, Sendable, Equatable {
    case mp4

    /// File extension used when naming the recorded artifact. Kept as a
    /// derived property so adding `.mov` or `.mkv` later doesn't fork
    /// every call site that builds an output path.
    var fileExtension: String { rawValue }
}
