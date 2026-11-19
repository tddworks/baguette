import Foundation
import IOSurface

/// Records a simulator's screen onto a `Reel`.
///
/// The value-domain half of `baguette record`: subscribe to the
/// `Screen`, resolve the requested `CaptureSize` against the first frame
/// the simulator actually delivers, pace arrivals onto the requested
/// frame rate, stop at the requested duration, and report what was
/// written. Every one of those is a decision, so all of it is here and
/// unit-tested; the `AVAssetWriter` conversation lives behind `Reel`.
///
/// ## Why a server-side recorder is right *here* and wrong for `serve`
///
/// `docs/features/recording/README.md` records that server-side recording was
/// tried for the live-stream / device-farm case and rejected twice over:
/// an `ffmpeg -c copy` tap never sees the SPS/PPS that `H264Encoder`
/// emits only on the first IDR, and a parallel `Screen` subscription
/// with its own `AVAssetWriter` adds an N+1th VideoToolbox session on
/// top of the one every booted device already runs for its live stream,
/// which makes every farm tile stutter.
///
/// Neither reason survives the standalone CLI. `baguette record` owns
/// the encode from the very first frame (so there is no mid-stream
/// attach and no keep-alive duplicate to propagate), and it has no
/// competing live stream (so its VideoToolbox session is the only one).
/// The rejected approach is therefore the *correct* approach here — and
/// only here. This type is deliberately not reachable from
/// `baguette serve`; the browser stays the recorder for live sessions.
public final class ScreenRecorder: @unchecked Sendable {

    private let screen: any Screen
    private let reel: any Reel
    private let plan: RecordingPlan
    private let output: URL
    private let clock: @Sendable () -> Double

    private let lock = NSLock()
    private var recording = false
    private var closed = false
    /// Wall-clock reading taken when `start()` subscribed. `--duration`
    /// is measured from here, not from the first frame: an idle
    /// simulator delivers nothing at all, and a recording that could
    /// only end once the screen changed would never end.
    private var startedAt: Double = 0
    private var cadence: FrameCadence
    private var placement: CapturePlacement?
    private var frames = 0
    private var lastFrameTime: Double = 0
    /// A writer that refused to open. Kept so `finish()` reports *that*
    /// rather than blaming the simulator for delivering no frames.
    private var openFailure: Error?

    /// `clock` is injected so the suites can drive the cadence and the
    /// duration cut-off deterministically instead of sleeping.
    public init(
        screen: any Screen,
        reel: any Reel,
        plan: RecordingPlan,
        output: URL,
        clock: @escaping @Sendable () -> Double = {
            Date().timeIntervalSinceReferenceDate
        }
    ) {
        self.screen = screen
        self.reel = reel
        self.plan = plan
        self.output = output
        self.clock = clock
        self.cadence = FrameCadence(fps: plan.fps)
    }

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recording
    }

    public var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    /// Subscribe to the simulator's frames. Throws whatever the screen
    /// throws — a shutdown simulator has no framebuffer to wire.
    public func start() throws {
        lock.lock()
        recording = true
        startedAt = clock()
        lock.unlock()

        do {
            try screen.start { [weak self] surface in
                self?.receive(surface)
            }
        } catch {
            lock.lock()
            recording = false
            lock.unlock()
            throw error
        }
    }

    /// Stop accepting frames and let go of the screen. Idempotent — both
    /// the duration cut-off and the user's Ctrl-C route through here.
    public func stop() {
        lock.lock()
        guard recording else { lock.unlock(); return }
        recording = false
        lock.unlock()
        screen.stop()
    }

    /// Stop, flush the reel, and report what landed on disk. Throws the
    /// writer's own failure if there was one, and `noFramesCaptured`
    /// rather than leaving a zero-frame file behind.
    @discardableResult
    public func finish() async throws -> RecordingSummary {
        stop()
        let claim = claimClose()

        if let failure = claim.openFailure { throw failure }
        guard claim.summary.frameCount > 0 else {
            // The reel is open over a file with no video in it. Throw
            // the whole take away so the user's `--output` path is left
            // as it was, rather than holding an unplayable stub.
            if claim.opened && !claim.alreadyClosed { reel.discard() }
            throw RecordingError.noFramesCaptured
        }
        if !claim.alreadyClosed {
            do {
                try await reel.close()
            } catch {
                // A writer that failed to flush left nothing playable
                // behind, so the take is not closed and must not be
                // reported as one. Reopening the claim means a second
                // `finish()` raises the failure again instead of
                // handing back a summary for a file that isn't there.
                reopenClaim()
                throw error
            }
        }
        return claim.summary
    }

    /// Snapshot the recording and mark it closed, in one atomic step so
    /// a second `finish()` can't double-close the reel. Split out of the
    /// async `finish()` because `NSLock` is unavailable from an async
    /// context.
    private func claimClose() -> (
        alreadyClosed: Bool,
        opened: Bool,
        summary: RecordingSummary,
        openFailure: Error?
    ) {
        lock.lock(); defer { lock.unlock() }
        let alreadyClosed = closed
        closed = true
        return (alreadyClosed, placement != nil, currentSummary(), openFailure)
    }

    /// Give the claim back after a close that threw, so the take is
    /// still open as far as the next `finish()` is concerned.
    private func reopenClaim() {
        lock.lock(); defer { lock.unlock() }
        closed = false
    }

    // MARK: - Frame intake

    /// Runs on the screen's own dispatch queue.
    ///
    /// The whole intake — the reel handshake included — happens under
    /// `lock`. `finish()` can land on another thread at any moment, and
    /// opening the reel outside the lock would let `finish()` flush a
    /// writer the screen thread opened a microsecond later, leaving an
    /// unflushed, unplayable file behind while the summary reported
    /// success.
    private func receive(_ surface: IOSurface) {
        lock.lock()

        guard recording else { lock.unlock(); return }

        let elapsed = clock() - startedAt
        if let duration = plan.duration, elapsed > duration {
            lock.unlock()
            stop()
            return
        }

        // The first frame anchors the file at zero however long the
        // simulator took to produce it — a screen that only starts
        // changing three seconds in still opens the video on that
        // frame, held, rather than on three seconds of nothing.
        let isFirst = placement == nil
        let time = isFirst ? 0 : elapsed
        guard cadence.accepts(time) else { lock.unlock(); return }

        if isFirst {
            // The simulator's own frame size is the source every
            // requested size resolves against — it isn't known until a
            // surface actually shows up.
            let dimensions = RenderDimensions(
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface)
            )
            let resolved = plan.placement(source: dimensions)
            do {
                try reel.open(to: output, placement: resolved, plan: plan)
            } catch {
                // Nothing downstream can recover a writer that refused
                // to open; end the recording so `finish()` reports it.
                openFailure = error
                lock.unlock()
                stop()
                return
            }
            placement = resolved
        }

        // The reel drops a frame the encoder isn't ready for, so the
        // summary counts what was written, not what was offered.
        let written = reel.append(frame: surface, at: time)
        if written {
            frames += 1
            lastFrameTime = time
        }
        lock.unlock()
    }

    /// Caller holds `lock`.
    private func currentSummary() -> RecordingSummary {
        RecordingSummary(
            output: output,
            frameCount: frames,
            // The file runs one frame interval past its last frame —
            // that frame is on screen for its own duration too.
            duration: frames > 0 ? lastFrameTime + plan.frameInterval : 0,
            width: placement?.width ?? 0,
            height: placement?.height ?? 0
        )
    }
}

/// What a finished recording put on disk — printed to stderr by
/// `baguette record` so a script can see the shape of what it got.
public struct RecordingSummary: Equatable, Sendable {
    public let output: URL
    public let frameCount: Int
    public let duration: Double
    public let width: Int
    public let height: Int

    public init(output: URL, frameCount: Int, duration: Double, width: Int, height: Int) {
        self.output = output
        self.frameCount = frameCount
        self.duration = duration
        self.width = width
        self.height = height
    }
}
