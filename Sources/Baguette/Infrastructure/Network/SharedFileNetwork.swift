import Foundation

/// `Network` backed by a small JSON file both sides can see, plus the
/// shared `DYLD_INSERT_LIBRARIES` arming.
///
/// The simulator shares the host's `/tmp`, which is how the camera already
/// hands frames to its dylib through `/tmp/SimCam.bgra` and motion its
/// intent through `/tmp/BaguetteMotion.json`. A condition is a handful of
/// numbers that changes only when someone changes it, so it's a plain
/// atomic file write.
///
/// The file is a **single current value, not a log**: each publish replaces
/// it, because a dylib reading a concatenation would fail to parse and
/// condition nothing — which looks exactly like the feature being off.
final class SharedFileNetwork: Network, @unchecked Sendable {

    /// Where the condition is published for `udid`. Same shared-`/tmp`
    /// convention as the camera's frame buffer, but **scoped per
    /// simulator**: every simulator sees the host's `/tmp`, so a single
    /// shared file would mean conditioning one device replaced the
    /// condition an injected app on another was still reading. The dylib
    /// builds this same path from its own `SIMULATOR_UDID`.
    static func path(forUDID udid: String) -> String {
        "/tmp/BaguetteNetwork-\(udid).json"
    }

    private let fileURL: URL
    /// `nil` when this build didn't ship the dylib — applying then fails
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

    func apply(_ condition: NetworkCondition, on simulator: any Simulator) async throws {
        // Refuse before touching anything: an empty DYLD_INSERT_LIBRARIES
        // entry makes dyld log a load failure for every app launched
        // afterwards, and a condition nobody reads looks like success.
        guard let dylibPath, !dylibPath.isEmpty else { throw NetworkError.dylibMissing }
        try publish(condition)
        try await injection.arm(dylibPath: dylibPath, on: simulator)
    }

    func clear(on simulator: any Simulator) async throws {
        guard let dylibPath, !dylibPath.isEmpty else { return }
        // Publish *before* disarming, and publish an explicit unconditioned
        // value rather than deleting the file.
        //
        // Disarming only stops future launches loading the dylib. An app
        // already running still has it loaded and still reads this file, so
        // leaving the last condition in place would keep that app throttled
        // for as long as it runs — and a forgotten throttle presents as
        // "the app is slow", not as an obvious mistake. Deleting instead
        // would leave a live reader interpreting an absent file, and "no
        // file means no conditioning" is only a safe rule if it can never be
        // ambiguous. Saying it outright is cheaper than relying on that.
        try publish(.unconditioned)
        try await injection.disarm(dylibPath: dylibPath, on: simulator)
    }

    func current(on simulator: any Simulator) async throws -> NetworkCondition? {
        guard let dylibPath, !dylibPath.isEmpty else { return nil }
        // Armed first. The file is per-simulator, but a device can still
        // hold a stale one without the dylib armed — a simulator reboot
        // clears `DYLD_INSERT_LIBRARIES` and leaves the condition behind.
        // Answering from the file alone would report a throttle on a
        // simulator that has none.
        guard try await injection.armed(dylibPath: dylibPath, on: simulator) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let condition = try? NetworkCondition(decoding: data),
              !condition.isUnconditioned else { return nil }
        return condition
    }

    private func publish(_ condition: NetworkCondition) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        // Atomic, so a dylib reading concurrently never sees a half-written
        // condition — it either parses the old one or the new one.
        try condition.encoded().write(to: fileURL, options: .atomic)
    }
}
