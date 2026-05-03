import Testing
import Foundation
@testable import Baguette

@Suite("RecordingArtifact")
struct RecordingArtifactTests {

    @Test func `filename is the URL's last path component`() {
        let artifact = RecordingArtifact(
            url: URL(fileURLWithPath: "/tmp/baguette/abc-123.mp4"),
            format: .mp4,
            durationSeconds: 12.5,
            bytes: 1_048_576
        )
        #expect(artifact.filename == "abc-123.mp4")
    }

    @Test func `dictionary projection carries filename, format, duration, bytes`() {
        let artifact = RecordingArtifact(
            url: URL(fileURLWithPath: "/tmp/x.mp4"),
            format: .mp4,
            durationSeconds: 3.25,
            bytes: 999
        )
        let dict = artifact.dictionary
        #expect(dict["filename"] as? String == "x.mp4")
        #expect(dict["format"]   as? String == "mp4")
        #expect(dict["duration"] as? Double == 3.25)
        #expect(dict["bytes"]    as? Int64  == 999)
    }
}

@Suite("RecordingFormat")
struct RecordingFormatTests {

    @Test func `mp4 file extension is mp4`() {
        #expect(RecordingFormat.mp4.fileExtension == "mp4")
    }

    @Test func `raw value round-trips`() {
        #expect(RecordingFormat(rawValue: "mp4") == .mp4)
        #expect(RecordingFormat(rawValue: "wat") == nil)
    }
}
