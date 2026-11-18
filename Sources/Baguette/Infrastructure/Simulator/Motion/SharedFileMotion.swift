import Foundation

/// `Motion` backed by a small JSON file both sides can see, plus the
/// shared `DYLD_INSERT_LIBRARIES` arming.
///
/// The simulator shares the host's `/tmp`, which is how the camera already
/// hands frames to its dylib through `/tmp/SimCam.bgra`. Motion needs far
/// less bandwidth — one small intent whenever the device changes what it's
/// doing — so it's a plain atomic file write rather than a mapped ring
/// buffer.
///
/// The file is a **single current value, not a log**: each publish replaces
/// it, because a dylib reading a concatenation would fail to parse and
/// therefore see no motion at all.
final class SharedFileMotion: Motion, @unchecked Sendable {

    /// Where the intent is published for `udid`. Same shared-`/tmp`
    /// convention as the camera's frame buffer, but **scoped per simulator**:
    /// every simulator sees the host's `/tmp`, so a single shared file meant
    /// publishing for one device replaced the intent an injected app on
    /// another was still reading. The dylib builds this same path from its
    /// own `SIMULATOR_UDID`.
    static func path(forUDID udid: String) -> String {
        "/tmp/BaguetteMotion-\(udid).json"
    }

    private let fileURL: URL
    /// `nil` when this build didn't ship the dylib — publishing then fails
    /// loudly rather than arming nothing.
    private let dylibPath: String?
    private let injection: any SimulatorInjection

    init(
        fileURL: URL,
        dylibPath: String?,
        injection: any SimulatorInjection = SimctlSimulatorInjection()
    ) {
        self.fileURL = fileURL
        self.dylibPath = dylibPath
        self.injection = injection
    }

    func publish(_ intent: MotionIntent, on simulator: any Simulator) async throws {
        // Refuse before touching anything: an empty DYLD_INSERT_LIBRARIES
        // entry makes dyld log a load failure for every app launched
        // afterwards, and an intent nobody reads looks like success.
        guard let dylibPath, !dylibPath.isEmpty else { throw MotionError.dylibMissing }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        // Atomic, so a dylib reading concurrently never sees a half-written
        // intent — it either parses the old one or the new one.
        try intent.encoded().write(to: fileURL, options: .atomic)
        try await injection.arm(dylibPath: dylibPath, on: simulator)
    }

    func published() -> MotionIntent? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? MotionIntent(decoding: data)
    }

    func clear(on simulator: any Simulator) async throws {
        // The file is deliberately left in place. Disarming only stops
        // *future* launches loading the dylib; an app already running still
        // has it loaded and still reads this file, so deleting it would
        // leave a live reader with nothing to read. Callers park the device
        // with a stationary publish first, and that parked value is what a
        // running app keeps seeing.
        guard let dylibPath, !dylibPath.isEmpty else { return }
        try await injection.disarm(dylibPath: dylibPath, on: simulator)
    }
}

/// Failure modes the motion surface surfaces. Maps to a CLI exit message /
/// HTTP error body.
enum MotionError: Error, Equatable, CustomStringConvertible {
    /// This build doesn't carry `VirtualMotion.dylib`, so there's nothing to
    /// inject and nothing would read a published intent.
    case dylibMissing

    var description: String {
        switch self {
        case .dylibMissing:
            return "VirtualMotion.dylib is not bundled in this build"
        }
    }
}
