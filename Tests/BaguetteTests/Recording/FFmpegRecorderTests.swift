import Testing
import Foundation
@testable import Baguette

/// FFmpegRecorder is a thin shell around a Process — its byte
/// composition is fully covered by the AnnexBAssembler / AVCCToAnnexB
/// suites. The tests here exercise the lifecycle states that don't
/// require a real ffmpeg run on the box: error reporting on bad
/// configuration, and clean cancel() semantics.
@Suite("FFmpegRecorder")
struct FFmpegRecorderTests {

    @Test func `finish before any write throws emptyOutput`() {
        let url = uniqueTemp()
        let recorder = FFmpegRecorder(outputURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: FFmpegRecorder.FFmpegError.self) {
            _ = try recorder.finish()
        }
    }

    @Test func `cancel before write is a no-op (no crash, no file)`() {
        let url = uniqueTemp()
        let recorder = FFmpegRecorder(outputURL: url)
        recorder.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func `delta before description is dropped (no spawn)`() {
        // Without a `description` write, the assembler suppresses every
        // delta, so ffmpeg never spawns and finish() reports empty.
        let url = uniqueTemp()
        let recorder = FFmpegRecorder(outputURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        recorder.write(delta: Data([0, 0, 0, 2, 0x41, 0x9A]))

        #expect(throws: FFmpegRecorder.FFmpegError.self) {
            _ = try recorder.finish()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func uniqueTemp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-rec-test-\(UUID().uuidString).mp4")
    }
}
