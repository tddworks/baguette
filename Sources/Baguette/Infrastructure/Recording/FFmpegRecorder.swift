import Foundation

/// Concrete `H264Recorder` that pipes Annex B NALUs into a long-lived
/// `ffmpeg` subprocess and lets it mux to MP4 with `-c copy` — no
/// re-encode, near-zero CPU. ffmpeg is launched lazily on the first
/// `description()` call so a misconfigured environment doesn't burn a
/// process before any frames arrive.
///
/// Lifecycle:
///   start()       : caller-side; reserves the output URL.
///   write(...)    : pipes Annex B to ffmpeg's stdin. First call also
///                   spawns the subprocess.
///   finish()      : closes stdin, waits for ffmpeg to exit, returns
///                   the artifact (URL + size + duration).
///   cancel()      : terminates ffmpeg without producing an artifact;
///                   leaves any partial file on disk for inspection.
final class FFmpegRecorder: H264Recorder, @unchecked Sendable {

    enum FFmpegError: Error, CustomStringConvertible, Equatable {
        case binaryNotFound
        case processFailed(status: Int32)
        case emptyOutput

        var description: String {
            switch self {
            case .binaryNotFound:
                return "ffmpeg not found on PATH or known Homebrew prefixes"
            case .processFailed(let status):
                return "ffmpeg exited with status \(status)"
            case .emptyOutput:
                return "ffmpeg produced an empty file"
            }
        }
    }

    /// Search order for the ffmpeg binary. The Process spawned by
    /// Foundation doesn't inherit the user's interactive shell PATH, so
    /// we probe the common Homebrew prefixes explicitly before falling
    /// back to whatever is in $PATH.
    static let candidatePaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    let outputURL: URL
    private let lock = NSLock()
    private var assembler = AnnexBAssembler()
    private var process: Process?
    private var stdin: FileHandle?
    private var startTime: Date?
    private var endTime: Date?
    private var spawnFailed = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    // MARK: - H264Recorder

    func write(description avcc: Data) {
        lock.lock(); defer { lock.unlock() }
        assembler.description(avcc)
        if process == nil { _ = trySpawn() }
    }

    func write(keyframe avcc: Data) {
        lock.lock(); defer { lock.unlock() }
        let bytes = assembler.keyframe(avcc)
        guard !bytes.isEmpty else { return }
        if process == nil { _ = trySpawn() }
        feed(bytes)
    }

    func write(delta avcc: Data) {
        lock.lock(); defer { lock.unlock() }
        let bytes = assembler.delta(avcc)
        guard !bytes.isEmpty else { return }
        feed(bytes)
    }

    func finish() throws -> RecordingArtifact {
        lock.lock()
        let proc = process
        let pipe = stdin
        let started = startTime
        process = nil
        stdin = nil
        lock.unlock()

        if spawnFailed { throw FFmpegError.binaryNotFound }
        guard let proc, let pipe, let started else { throw FFmpegError.emptyOutput }

        try? pipe.close()
        proc.waitUntilExit()
        endTime = Date()

        let status = proc.terminationStatus
        guard status == 0 else { throw FFmpegError.processFailed(status: status) }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw FFmpegError.emptyOutput }

        return RecordingArtifact(
            url: outputURL,
            format: .mp4,
            durationSeconds: (endTime ?? Date()).timeIntervalSince(started),
            bytes: size
        )
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        try? stdin?.close()
        stdin = nil
        process?.terminate()
        process = nil
    }

    // MARK: - private

    /// Spawn ffmpeg and remember the pipe handles. Caller holds `lock`.
    /// Returns false when no usable ffmpeg binary is on the box; the
    /// recorder then drops every write until finish() reports the failure.
    private func trySpawn() -> Bool {
        guard let bin = Self.locateFFmpeg() else {
            spawnFailed = true
            return false
        }

        // Ensure the parent directory exists. The server hands us a path
        // under a Baguette-managed temp dir, but the dir is per-process
        // and may not have been created yet when the very first
        // recording starts.
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-fflags", "+genpts",
            "-f", "h264",
            "-i", "pipe:0",
            "-c", "copy",
            "-movflags", "+faststart",
            outputURL.path,
        ]
        proc.standardInput  = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            spawnFailed = true
            return false
        }
        self.process = proc
        self.stdin = pipe.fileHandleForWriting
        self.startTime = Date()
        return true
    }

    /// Pump bytes into ffmpeg's stdin. Errors here mean ffmpeg exited
    /// (closed pipe / broken pipe) — record the failure and drop the
    /// rest of the stream rather than crashing the encode queue.
    private func feed(_ data: Data) {
        guard let pipe = stdin else { return }
        do {
            try pipe.write(contentsOf: data)
        } catch {
            try? pipe.close()
            stdin = nil
            // process exited; finish() will see the non-zero status.
        }
    }

    private static func locateFFmpeg() -> String? {
        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
