import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `AVVideoDecoder` is the AVFoundation half of video-file playback.
/// The pacing/looping logic above it is covered against
/// `MockVideoDecoder` in `VideoFileCaptureTests`; this suite drives the
/// real reader against a real asset, because the parts worth pinning
/// down — the BGRA request, the fit, the row-padding strip, rewinding,
/// the not-started/no-track errors — only exist against `AVAssetReader`.
///
/// `.serialized` is load-bearing, not tidiness: several `AVAssetReader`s
/// decoding at once deadlock on a small CI runner. Every reader parks in
/// `copyNextSampleBuffer` -> MediaToolbox -> `FigSemaphoreWaitRelative`
/// and none ever wakes, so the whole test process hangs until the job
/// times out — an 8-core dev Mac has the headroom to hide it, a 3-core
/// runner does not. One reader at a time is fine, so the suite decodes
/// one at a time.
///
/// Both fixtures hold 4 frames at 30 fps of solid grey ramping 40, 60,
/// 80, 100 — consecutive frames decode to distinct pixels, which is what
/// lets the rewind test prove it landed back on frame 0 specifically.
/// Regenerate with `Tests/BaguetteTests/Fixtures/README.md`.
@Suite("AVVideoDecoder", .serialized)
struct AVVideoDecoderTests {

    /// Copy a fixture out of the test bundle into a temp file. The
    /// decoder takes a path, and a caller staging an upload hands it one
    /// in a temp dir — so read it the same way rather than off the
    /// bundle's read-only resource path.
    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"),
            "missing fixture \(name).mp4 — see Fixtures/README.md"
        )
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-vidtest-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy.path
    }

    /// 2000×1000 — forces a downscale against the 1280 canvas cap; the
    /// odd aspect also proves the fit isn't square.
    private func wideVideo() throws -> String { try fixture("ramp-2000x1000") }

    /// 320×240 — comfortably under the canvas cap, so nothing is scaled.
    private func smallVideo() throws -> String { try fixture("ramp-320x240") }

    @Test func `should report the decoder not started when a frame is read before start`() {
        let decoder = AVVideoDecoder()
        #expect(throws: VideoDecoderError.notStarted) {
            _ = try decoder.nextFrame()
        }
    }

    @Test func `should fail to start when the file is not a readable video`() async {
        let decoder = AVVideoDecoder()
        await #expect(throws: (any Error).self) {
            try await decoder.start(path: "/tmp/does-not-exist-\(UUID().uuidString).mp4", maxDimension: 1280)
        }
    }

    @Test func `should fail to start when the file has no video track`() async throws {
        // A .mp4 extension over bytes that aren't a movie at all.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-notavideo-\(UUID().uuidString).mp4")
        try Data(repeating: 0, count: 512).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = AVVideoDecoder()
        await #expect(throws: (any Error).self) {
            try await decoder.start(path: url.path, maxDimension: 1280)
        }
    }

    @Test func `should decode video frames fitted to the canvas as tightly packed BGRA`() async throws {
        let path = try wideVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        let frame = try #require(try decoder.nextFrame())
        // 2000×1000 fitted into the 1280 canvas → 1280×640.
        #expect(frame.width == 1280)
        #expect(frame.height == 640)
        // Tightly packed: the decoder strips the CVPixelBuffer's row
        // padding, which 1280×4 wouldn't reveal on its own — the shared
        // buffer's reader assumes width*4 stride.
        #expect(frame.pixels.count == 1280 * 640 * 4)
    }

    @Test func `should not upscale a video smaller than the canvas`() async throws {
        let path = try smallVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        let frame = try #require(try decoder.nextFrame())
        #expect(frame.width == 320)
        #expect(frame.height == 240)
    }

    @Test func `should decode frames in presentation order and run out at the end of the video`() async throws {
        let path = try smallVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        var timestamps: [UInt32] = []
        while let frame = try decoder.nextFrame() { timestamps.append(frame.presentationMs) }

        #expect(timestamps.count == 4)
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.first == 0)
        // 30 fps → ~33 ms apart; the last of 4 lands near 100 ms.
        #expect(timestamps.last! > 0)
        // Exhausted: further pulls keep reporting EOF rather than throwing.
        #expect(try decoder.nextFrame() == nil)
    }

    @Test func `should replay the video from its first frame when rewound`() async throws {
        let path = try smallVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        let first = try #require(try decoder.nextFrame())
        while try decoder.nextFrame() != nil {}  // drain to EOF

        try await decoder.rewind()
        let replayed = try #require(try decoder.nextFrame())
        #expect(replayed.presentationMs == first.presentationMs)
        #expect(replayed.pixels == first.pixels)
    }

    @Test func `should end decoding when stopped and allow starting again`() async throws {
        let path = try smallVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        _ = try decoder.nextFrame()
        decoder.stop()

        #expect(throws: VideoDecoderError.notStarted) {
            _ = try decoder.nextFrame()
        }

        // start after stop is a fresh read of the same asset.
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }
        #expect(try decoder.nextFrame() != nil)
    }

    /// `start` on a live decoder must cancel the reader it replaces
    /// rather than orphan it — so a restart reads from the top.
    @Test func `should restart from the first frame when started again while decoding`() async throws {
        let path = try smallVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }
        let first = try #require(try decoder.nextFrame())
        _ = try decoder.nextFrame()

        try await decoder.start(path: path, maxDimension: 1280)
        let afterRestart = try #require(try decoder.nextFrame())
        #expect(afterRestart.presentationMs == first.presentationMs)
    }
}
