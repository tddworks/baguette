import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

@Suite("VideoFileCapture orchestrator")
struct VideoFileCaptureTests {

    /// Hands out a looping script of decoded frames; `nil` marks EOF.
    final class Feed: @unchecked Sendable {
        private let script: [DecodedVideoFrame?]
        private var idx = 0
        init(_ script: [DecodedVideoFrame?]) { self.script = script }
        func next() -> DecodedVideoFrame? {
            defer { idx += 1 }
            return script[idx % script.count]
        }
    }

    final class Recorder: @unchecked Sendable {
        var frames: [CameraFrame] = []
        func record(_ f: CameraFrame) { frames.append(f) }
        var count: Int { frames.count }
    }

    final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private func decoded(pts: UInt32) -> DecodedVideoFrame {
        DecodedVideoFrame(pixels: Data(count: 16), width: 2, height: 2, presentationMs: pts)
    }

    /// Poll until `cond` holds or a short deadline elapses.
    private func waitUntil(_ cond: @escaping @Sendable () -> Bool) async {
        for _ in 0..<200 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func `should refuse to start the video capture when the source is not a video`() async {
        let cap = VideoFileCapture(decoder: MockVideoDecoder())
        await #expect(throws: (any Error).self) {
            try await cap.start(source: .image(path: "/tmp/pic.png")) { _ in }
        }
    }

    @Test func `should deliver video frames in increasing sequence and loop the video at its end`() async throws {
        let decoder = MockVideoDecoder()
        let feed = Feed([decoded(pts: 0), decoded(pts: 20), nil])  // 2 frames, then loop
        let rewinds = Counter()
        given(decoder).start(path: .any, maxDimension: .any).willReturn(())
        given(decoder).nextFrame().willProduce { feed.next() }
        given(decoder).rewind().willProduce { rewinds.bump() }
        given(decoder).stop().willReturn(())

        let rec = Recorder()
        let cap = VideoFileCapture(decoder: decoder)
        try await cap.start(source: .video(path: "/tmp/clip.mp4")) { rec.record($0) }

        // Four frames means we crossed the EOF boundary at least once.
        await waitUntil { rec.count >= 4 }
        await cap.stop()

        #expect(Array(rec.frames.prefix(4)).map(\.sequence) == [1, 2, 3, 4])
        #expect(rewinds.value >= 1)
    }

    /// `stop` cancels the pump mid-pace. The cancellation surfaces as a
    /// throw from the pacing sleep, which is swallowed — so without an
    /// explicit check the loop runs on to emit one more frame into a
    /// buffer nobody is streaming any more.
    @Test func `should deliver no frame after the video capture stops`() async throws {
        let decoder = MockVideoDecoder()
        // 500 ms apart, so the pump is parked in the pacing sleep when
        // stop lands.
        let feed = Feed([decoded(pts: 0), decoded(pts: 500), decoded(pts: 1000)])
        given(decoder).start(path: .any, maxDimension: .any).willReturn(())
        given(decoder).nextFrame().willProduce { feed.next() }
        given(decoder).rewind().willReturn(())
        given(decoder).stop().willReturn(())

        let rec = Recorder()
        let cap = VideoFileCapture(decoder: decoder)
        try await cap.start(source: .video(path: "/tmp/clip.mp4")) { rec.record($0) }
        await waitUntil { rec.count >= 1 }

        let settled = rec.count
        await cap.stop()
        // Comfortably longer than a zombie frame would need to land,
        // comfortably shorter than the 500 ms pace it was sleeping off.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(rec.count == settled)
    }

    /// A corrupt asset can report a timestamp far past its neighbour.
    /// Paced literally that becomes a sleep of days and the feed simply
    /// dies, so the gap is capped — the sim's reader calls the buffer
    /// stale after ~1 s anyway, so pacing longer can't buy anything.
    @Test func `should cap an absurd gap between frames so the video keeps playing`() async throws {
        let decoder = MockVideoDecoder()
        let feed = Feed([decoded(pts: 0), decoded(pts: 10_000_000), nil])  // ~2.8 hours apart
        given(decoder).start(path: .any, maxDimension: .any).willReturn(())
        given(decoder).nextFrame().willProduce { feed.next() }
        given(decoder).rewind().willReturn(())
        given(decoder).stop().willReturn(())

        let rec = Recorder()
        let cap = VideoFileCapture(decoder: decoder, maxPacingGapMs: 20)
        try await cap.start(source: .video(path: "/tmp/clip.mp4")) { rec.record($0) }

        await waitUntil { rec.count >= 2 }
        await cap.stop()
        #expect(rec.count >= 2, "the second frame must not wait out its real gap")
    }

    @Test func `should stop decoding when the video capture stops`() async throws {
        let decoder = MockVideoDecoder()
        let feed = Feed([decoded(pts: 0)])
        given(decoder).start(path: .any, maxDimension: .any).willReturn(())
        given(decoder).nextFrame().willProduce { feed.next() }
        given(decoder).rewind().willReturn(())
        given(decoder).stop().willReturn(())

        let cap = VideoFileCapture(decoder: decoder)
        try await cap.start(source: .video(path: "/tmp/clip.mp4")) { _ in }
        await cap.stop()

        verify(decoder).stop().called(1)
    }
}
