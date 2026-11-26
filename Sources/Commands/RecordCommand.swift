import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Dispatch
import Foundation

/// `baguette record --udid <UDID> --output demo.mp4 [--size appstore-6.9] …`
///
/// Records a booted simulator's screen straight to an H.264 file, at the
/// same output sizes `baguette screenshot` and the browser's capture
/// picker speak (`docs/features/capture-size/README.md`).
///
/// **This is the one place server-side recording belongs.**
/// `docs/features/recording/README.md` rejects server-side recording for the
/// live-stream / device-farm case on two grounds — an `ffmpeg -c copy`
/// tap never sees the SPS/PPS `VideoEncoder` emits only on its first IDR,
/// and a parallel encode adds an N+1th VideoToolbox session next to the
/// one every booted device already runs for its live stream, which makes
/// every farm tile stutter. A standalone `record` has no competing live
/// stream and owns the encode from frame one, so neither objection
/// applies here. Nothing in this command is reachable from `baguette
/// serve`; the browser stays the recorder for live sessions.
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a simulator's screen to an H.264 video file",
        discussion: """
            Records until --duration elapses, or until Ctrl-C when no \
            duration is given; either way the file is flushed and \
            playable.

            SimulatorKit only delivers a frame when the screen actually \
            changes, so a recording of an idle simulator captures \
            nothing. Drive some input (baguette tap / swipe) while it \
            runs.

            Live browser sessions record in the browser instead — see \
            docs/features/recording/README.md.
            """
    )

    @OptionGroup var options: DeviceOption

    @Option(name: .shortAndLong, help: "Output video file — .mp4 or .mov")
    var output: String

    @Option(help: "Output size: \(CaptureSize.presetList), WIDTHxHEIGHT, or W:H")
    var size: String = "native"

    @Option(help: "Frame placement: contain | cover | stretch")
    var fit: String = "contain"

    @Option(help: "Letterbox background as #RRGGBB (video has no alpha)")
    var background: String = "#ffffff"

    @Option(help: "Frames per second (1 – 120)")
    var fps: Int = 30

    @Option(help: "Stop N seconds after launch (omit to record until Ctrl-C)")
    var duration: Double?

    @Option(help: "H.264 average bitrate (bps)")
    var bitrate: Int = 8_000_000

    // MARK: - Validation

    /// Rejects what the recorder can't honour — and normalises the rest,
    /// so validation is exactly as forgiving as the parsers behind it.
    /// `CaptureSize.parse` is already case-insensitive; `--fit` and
    /// `--background` are trimmed and lowercased here so a single
    /// command line doesn't accept `--size SQUARE` and then refuse
    /// `--fit COVER`. `screenshot` makes the same normalisation.
    mutating func validate() throws {
        do {
            _ = try CaptureSize.parse(size)
        } catch let error as CaptureSizeError {
            throw ValidationError(error.message)
        }

        fit = fit.trimmingCharacters(in: .whitespaces).lowercased()
        guard CaptureFit(rawValue: fit) != nil else {
            throw ValidationError(
                "--fit must be one of: "
                    + CaptureFit.allCases.map(\.rawValue).joined(separator: " | ")
            )
        }
        // `transparent` is rejected rather than quietly matted: video
        // has no alpha channel, and finding that out at parse time beats
        // discovering a colour you didn't choose in a ten-second take.
        background = background.trimmingCharacters(in: .whitespaces).lowercased()
        guard background.range(of: #"^#[0-9a-f]{6}$"#, options: .regularExpression)
            != nil else {
            throw ValidationError("--background must be #RRGGBB")
        }
        guard RecordingPlan.frameRateRange.contains(fps) else {
            throw ValidationError("--fps must be between 1 and 120")
        }
        guard bitrate > 0 else {
            throw ValidationError("--bitrate must be positive")
        }
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be positive")
        }
        do {
            _ = try RecordingFormat.forFile(URL(fileURLWithPath: output))
        } catch let error as RecordingError {
            throw ValidationError(error.message)
        }
    }

    // MARK: - Run

    /// The take the flags describe. `validate()` has normalised them.
    func plan() throws -> RecordingPlan {
        RecordingPlan(
            size: try CaptureSize.parse(size),
            fit: CaptureFit(rawValue: fit) ?? .contain,
            background: HexColor(background),
            fps: fps,
            bitrateBps: bitrate,
            duration: duration,
            format: try RecordingFormat.forFile(URL(fileURLWithPath: output))
        )
    }

    /// The line logged once the file is flushed.
    static func report(_ summary: RecordingSummary) -> String {
        String(
            format: "Recorded %d frames · %.2fs · %d×%d → %@",
            summary.frameCount, summary.duration,
            summary.width, summary.height, summary.output.path
        )
    }

    func run() async throws {
        let url = URL(fileURLWithPath: output)
        let plan = try self.plan()

        // A device that isn't running has no screen to record: refused up
        // front, rather than sitting out --duration and then blaming a
        // still screen.
        let device = try options.device()
        let screen = try orExit { try device.require(.screen) }

        let recorder = ScreenRecorder(
            screen: screen,
            reel: AVAssetWriterReel(),
            plan: plan,
            output: url
        )

        // Ctrl-C and the duration timer both mean "that's the take" —
        // whichever fires first opens the gate exactly once, so the
        // reel is always flushed and the file always plays.
        let gate = RecordingGate()
        let restoreInterrupt = Terminal.current.onInterrupt([SIGINT]) { gate.open(.interrupt) }

        var timer: DispatchSourceTimer?
        if let duration {
            // The recorder refuses post-deadline frames on its own, off
            // the same launch-anchored clock; this timer is what wakes
            // us when the simulator goes quiet and stops delivering
            // frames altogether.
            let source = DispatchSource.makeTimerSource(queue: .global())
            source.schedule(deadline: .now() + duration)
            source.setEventHandler { gate.open(.duration) }
            source.resume()
            timer = source
        }

        do {
            try recorder.start()
        } catch {
            timer?.cancel()
            restoreInterrupt()
            tell("Recording failed to start: \(error)")
            throw ExitCode.failure
        }

        await gate.wait()
        let interrupted = gate.openedBy == .interrupt
        timer?.cancel()
        // Flushing a long recording takes seconds, and a Ctrl-C during
        // the flush kills the process mid-`finishWriting` — the one way
        // left to end up with a truncated file. So the signal only goes
        // back to the kernel when the user has *already* pressed once
        // and a second press is plausibly deliberate. On the --duration
        // path they haven't pressed at all, and their first press must
        // not be the one that breaks the file; SIGINT stays ignored
        // until the reel is closed (a second press meanwhile only knocks
        // on the gate that is already open).
        if interrupted { restoreInterrupt() }
        defer { restoreInterrupt() }

        do {
            let summary = try await recorder.finish()
            tell(Self.report(summary))
        } catch let error as RecordingError {
            tell(error.message)
            throw ExitCode.failure
        }
    }
}

/// A one-shot latch an async caller waits on and a `DispatchSource`
/// handler opens. Both the SIGINT source and the duration timer can fire;
/// only the first one through resumes the continuation — and the gate
/// remembers which, because that decides what SIGINT does next.
final class RecordingGate: @unchecked Sendable {

    /// Why the take ended.
    enum Reason: Equatable, Sendable {
        case interrupt
        case duration
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var reason: Reason?

    /// The reason the gate opened, or `nil` while it's still shut.
    var openedBy: Reason? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if reason != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open(_ reason: Reason) {
        lock.lock()
        guard self.reason == nil else { lock.unlock(); return }
        self.reason = reason
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}
