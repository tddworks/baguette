import Testing
import Foundation
import IOSurface
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Orchestration coverage for `ScreenRecorder` — the value-domain half of
/// `baguette record`: resolving the requested output size against the
/// simulator's own frame, pacing frames onto the requested cadence,
/// stopping itself at the requested duration, and reporting what it
/// wrote. The irreducible `AVAssetWriter` conversation lives in
/// `AVAssetWriterReel` (integration-only), so every branch here is driven
/// through `MockReel` + `MockScreen`.
@Suite("ScreenRecorder")
struct ScreenRecorderTests {

    // MARK: - Test rig

    /// Records everything the reel and the screen were asked to do, out of
    /// the screen-callback closure.
    final class Captures: @unchecked Sendable {
        var onFrame: (@Sendable (IOSurface) -> Void)?
        var openedAt: URL?
        var opened = 0
        var placement: CapturePlacement?
        var appended: [Double] = []
        var offered = 0
        var closed = 0
        var discarded = 0
        var screenStopped = 0

        func deliver(_ surface: IOSurface, times: Int = 1) {
            guard let onFrame else {
                Issue.record("screen was never subscribed to")
                return
            }
            for _ in 0..<times { onFrame(surface) }
        }
    }

    /// A canned wall clock — one reading per delivered frame.
    final class Ticker: @unchecked Sendable {
        private let times: [Double]
        private var index = 0
        init(_ times: [Double]) { self.times = times }
        func read() -> Double {
            defer { index += 1 }
            return times[min(index, times.count - 1)]
        }
    }

    private func makeSurface(
        _ width: Int = 1290, _ height: Int = 2796
    ) throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
        ]))
    }

    private func makePlan(
        size: CaptureSize = .native,
        fps: Int = 30,
        duration: Double? = nil
    ) -> RecordingPlan {
        RecordingPlan(
            size: size, fit: .contain, background: HexColor("#ffffff"),
            fps: fps, bitrateBps: 8_000_000, duration: duration, format: .mp4
        )
    }

    /// `clock` is read once when the recording starts and once per
    /// delivered frame, so `readings` always leads with the launch time.
    private func makeRecorder(
        plan: RecordingPlan,
        readings: [Double],
        startFailure: Error? = nil,
        openFailure: Error? = nil,
        closeFailure: Error? = nil,
        writes: [Bool] = []
    ) -> (ScreenRecorder, Captures) {
        let captures = Captures()
        let ticker = Ticker(readings)

        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in
            if let startFailure { throw startFailure }
            captures.onFrame = onFrame
        }
        given(screen).stop().willProduce { captures.screenStopped += 1 }

        let reel = MockReel()
        given(reel).open(to: .any, placement: .any, plan: .any)
            .willProduce { url, placement, _ in
                if let openFailure { throw openFailure }
                captures.opened += 1
                captures.openedAt = url
                captures.placement = placement
            }
        given(reel).append(frame: .any, at: .any).willProduce { _, time in
            // An empty `writes` means the encoder took everything.
            let written = writes.isEmpty
                || writes[min(captures.offered, writes.count - 1)]
            captures.offered += 1
            if written { captures.appended.append(time) }
            return written
        }
        given(reel).close().willProduce {
            captures.closed += 1
            if let closeFailure { throw closeFailure }
        }
        given(reel).discard().willProduce { captures.discarded += 1 }

        let recorder = ScreenRecorder(
            screen: screen,
            reel: reel,
            plan: plan,
            output: URL(fileURLWithPath: "/tmp/demo.mp4"),
            clock: { ticker.read() }
        )
        return (recorder, captures)
    }

    // MARK: - Sizing

    @Test func `should size the video from the first frame the simulator delivers`() throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(size: try CaptureSize.parse("square")),
            readings: [0, 0]
        )
        try recorder.start()
        captures.deliver(try makeSurface())

        #expect(captures.openedAt == URL(fileURLWithPath: "/tmp/demo.mp4"))
        #expect(captures.placement?.width == 2796)
        #expect(captures.placement?.height == 2796)
    }

    @Test func `should open the video once no matter how many frames arrive`() throws {
        let (recorder, captures) = makeRecorder(plan: makePlan(fps: 60), readings: [0, 0, 0.02, 0.04])
        try recorder.start()
        captures.deliver(try makeSurface(), times: 3)

        #expect(captures.opened == 1)
        #expect(captures.appended.count == 3)
    }

    // MARK: - Cadence

    @Test func `should drop frames that arrive faster than the requested frame rate`() throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10),
            readings: [0, 0, 0.02, 0.04, 0.1, 0.11, 0.2]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 6)

        #expect(captures.appended == [0, 0.1, 0.2])
    }

    @Test func `should time each frame from the start of the recording, not from the epoch`() throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10),
            readings: [1000, 1000, 1000.5]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 2)

        #expect(captures.appended == [0, 0.5])
    }

    @Test func `should start the video on the first frame even when the screen stays still at first`() throws {
        // Launch at 0, nothing changes until 3 s in. The frame that
        // finally arrives anchors the file at zero rather than the
        // video opening on three seconds of nothing.
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10),
            readings: [0, 3.0, 3.5]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 2)

        #expect(captures.appended == [0, 3.5])
    }

    // MARK: - Duration

    @Test func `should stop recording once the requested duration has elapsed`() throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10, duration: 1.0),
            readings: [0, 0, 0.5, 1.2]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 3)

        #expect(captures.appended == [0, 0.5])
        #expect(!recorder.isRecording)
        #expect(captures.screenStopped == 1)
    }

    @Test func `should keep recording for as long as frames arrive when no duration is given`() throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 1, duration: nil),
            readings: [0, 0, 60, 3600]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 3)

        #expect(captures.appended == [0, 60, 3600])
        #expect(recorder.isRecording)
    }

    @Test func `should ignore frames delivered after the recording stopped`() throws {
        let (recorder, captures) = makeRecorder(plan: makePlan(fps: 60), readings: [0, 0, 0.1, 0.2])
        try recorder.start()
        let surface = try makeSurface()
        captures.deliver(surface)
        recorder.stop()
        captures.deliver(surface)

        #expect(captures.appended == [0])
    }

    // MARK: - Finishing

    @Test func `should report the frames captured and the canvas written when a recording finishes`() async throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10, duration: nil),
            readings: [0, 0, 0.5, 1.0]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 3)

        let summary = try await recorder.finish()

        #expect(summary.output == URL(fileURLWithPath: "/tmp/demo.mp4"))
        #expect(summary.frameCount == 3)
        #expect(summary.width == 1290)
        #expect(summary.height == 2796)
        // One frame interval past the last frame — the span the file covers.
        #expect(abs(summary.duration - 1.1) < 1e-9)
        #expect(captures.closed == 1)
    }

    @Test func `should fail rather than write an empty file when no frame was ever seen`() async throws {
        let (recorder, captures) = makeRecorder(plan: makePlan(), readings: [0, 0])
        try recorder.start()

        await #expect(throws: RecordingError.noFramesCaptured) {
            _ = try await recorder.finish()
        }
        #expect(captures.closed == 0)
    }

    @Test func `should throw away a video that was opened but never written to`() async throws {
        // The encoder refused the only frame that ever arrived, so the
        // reel is open over a file with no video in it. Finishing must
        // clear that file away rather than leave an unplayable stub
        // sitting at the path the user named.
        let (recorder, captures) = makeRecorder(
            plan: makePlan(), readings: [0, 0], writes: [false]
        )
        try recorder.start()
        captures.deliver(try makeSurface())

        await #expect(throws: RecordingError.noFramesCaptured) {
            _ = try await recorder.finish()
        }
        #expect(captures.opened == 1)
        #expect(captures.discarded == 1)
        #expect(captures.closed == 0)
    }

    @Test func `should never report success on a retry when the video failed to close`() async throws {
        // `finishWriting` failing means the file on disk was never
        // flushed. Reporting "Recorded 3 frames" the second time asked
        // would be reporting on a file that doesn't play.
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10),
            readings: [0, 0, 0.5],
            closeFailure: RecordingError.writerFailed("disk full")
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 2)

        await #expect(throws: RecordingError.writerFailed("disk full")) {
            _ = try await recorder.finish()
        }
        await #expect(throws: RecordingError.writerFailed("disk full")) {
            _ = try await recorder.finish()
        }
    }

    @Test func `should throw nothing away when the video was never opened`() async throws {
        let (recorder, captures) = makeRecorder(plan: makePlan(), readings: [0, 0])
        try recorder.start()

        await #expect(throws: RecordingError.noFramesCaptured) {
            _ = try await recorder.finish()
        }
        #expect(captures.discarded == 0)
    }

    @Test func `should close the video once when the recording is finished twice`() async throws {
        let (recorder, captures) = makeRecorder(plan: makePlan(), readings: [0, 0])
        try recorder.start()
        captures.deliver(try makeSurface())

        _ = try await recorder.finish()
        _ = try await recorder.finish()

        #expect(captures.closed == 1)
        #expect(captures.screenStopped == 1)
    }

    // MARK: - Failure

    @Test func `should surface the failure when the screen will not start`() {
        struct Boom: Error {}
        let (recorder, _) = makeRecorder(
            plan: makePlan(), readings: [0, 0], startFailure: Boom()
        )
        #expect(throws: Boom.self) { try recorder.start() }
    }

    @Test func `should report a video that will not open rather than blame the simulator`() async throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(),
            readings: [0, 0],
            openFailure: RecordingError.writerFailed("cannot write /no/such/dir/demo.mp4")
        )
        try recorder.start()
        captures.deliver(try makeSurface())

        await #expect(
            throws: RecordingError.writerFailed("cannot write /no/such/dir/demo.mp4")
        ) {
            _ = try await recorder.finish()
        }
        #expect(!recorder.isRecording)
    }

    @Test func `should leave a frame the encoder was not ready for out of the summary`() async throws {
        let (recorder, captures) = makeRecorder(
            plan: makePlan(fps: 10),
            readings: [0, 0, 0.5, 1.0],
            writes: [true, false, true]
        )
        try recorder.start()
        captures.deliver(try makeSurface(), times: 3)

        let summary = try await recorder.finish()

        #expect(captures.offered == 3)
        #expect(captures.appended == [0, 1.0])
        #expect(summary.frameCount == 2)
        // The dropped frame doesn't stretch the reported span either.
        #expect(abs(summary.duration - 1.1) < 1e-9)
    }

    @Test func `should explain that the simulator screen never changed when no frames were captured`() {
        #expect(RecordingError.noFramesCaptured.message
            == "No frames captured — the simulator screen never changed. "
                + "Drive some input while recording.")
    }
}
