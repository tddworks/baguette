import Foundation

/// The result of a finished recording — a playable file on disk plus the
/// metadata the UI needs to present a download link. Produced by
/// `Recorder.finish()`; immutable.
struct RecordingArtifact: Equatable, Sendable {
    let url: URL
    let format: RecordingFormat
    let durationSeconds: Double
    let bytes: Int64

    /// Filename component, used as the last path segment of the
    /// download URL. Doesn't include directories — the server's
    /// recording route rebuilds the full path from `udid` + filename.
    var filename: String { url.lastPathComponent }

    /// JSON projection used by the WebSocket text frame the server
    /// sends after `stop_record`. Keys mirror what the browser side
    /// (`sim-stream.js` / `farm-focus.js`) reads to render the
    /// download link. Sorted keys keep snapshot tests deterministic.
    var dictionary: [String: Any] {
        [
            "filename": filename,
            "format":   format.rawValue,
            "duration": durationSeconds,
            "bytes":    bytes,
        ]
    }
}
