import Foundation

/// `Apps` backed by `xcrun simctl install <udid> <path>` — plus, for a
/// zipped app, a `ditto -x -k` extraction in front of it.
///
/// The orchestration here is pure: argv assembly (delegated to
/// `AppBundle.installArguments` / `AppArchive.extractArguments`), the
/// `Subprocess` exit handshake, and the pure
/// `AppArchive.installableApp` locator over the extracted entries. The
/// `Foundation.Process` plumbing lives in `HostSubprocess` (already
/// vendored for `LogStream`), so this file is unit-covered end-to-end
/// via `MockSubprocess` — only the real spawns are integration-only.
final class SimctlApps: Apps, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    private let subprocess: any Subprocess
    private let xcrun: URL
    private let ditto: URL
    private let maxExtractedBytes: Int64
    private let libraries: @Sendable () async throws -> InjectedDylibs
    private let env = URL(fileURLWithPath: "/usr/bin/env")

    /// `libraries` is what a launched app loads: the ones armed on the
    /// device plus `DefaultsLookups.dylib`, so the app baguette relaunches
    /// can say which preferences it looks up. Empty launches plainly.
    init(
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: any Subprocess = HostSubprocess(),
        libraries: @escaping @Sendable () async throws -> InjectedDylibs = { InjectedDylibs(paths: []) },
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        ditto: URL = URL(fileURLWithPath: "/usr/bin/ditto"),
        // The upload route caps the *compressed* body at 1 GiB, but a
        // deflate-packed zip can inflate orders of magnitude beyond
        // that (a zip bomb fills the disk before simctl ever runs).
        // Real app bundles compress a few-to-one, so 4 GiB extracted
        // refuses the pathological case without touching legit apps.
        maxExtractedBytes: Int64 = 4 << 30
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.xcrun = xcrun
        self.ditto = ditto
        self.maxExtractedBytes = maxExtractedBytes
        self.libraries = libraries
    }

    func install(_ app: AppBundle) async throws {
        let status = try await exitStatus(of: xcrun, arguments: app.installArguments(udid: udid, deviceSetPath: deviceSetPath))
        guard status == 0 else { throw AppsError.installFailed(status: status) }
    }

    func install(archive: AppArchive) async throws {
        // Refuse an honest over-cap archive before ditto writes a
        // single byte: the central directory declares each entry's
        // uncompressed size. An unreadable or unparseable file skips
        // this (ditto surfaces its own failure), and a forged-low
        // declaration still hits the post-extraction measurement.
        if let data = try? Data(contentsOf: archive.path, options: .mappedIfSafe),
           let declared = AppArchive.declaredUncompressedBytes(in: data),
           declared > maxExtractedBytes {
            throw AppsError.archiveTooLarge(bytes: declared, limit: maxExtractedBytes)
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let status = try await exitStatus(of: ditto, arguments: archive.extractArguments(to: dest))
        guard status == 0 else { throw AppsError.extractFailed(status: status) }

        let extracted = Self.regularFileBytes(under: dest)
        guard extracted <= maxExtractedBytes else {
            throw AppsError.archiveTooLarge(bytes: extracted, limit: maxExtractedBytes)
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        guard let appName = AppArchive.installableApp(amongExtracted: entries) else {
            throw AppsError.noAppInArchive
        }
        try await install(AppBundle(path: dest.appendingPathComponent(appName)))
    }

    func open(_ link: DeepLink) async throws {
        let status = try await exitStatus(of: xcrun, arguments: link.openArguments(udid: udid, deviceSetPath: deviceSetPath))
        guard status == 0 else { throw AppsError.openFailed(status: status) }
    }

    /// simctl reads the payload from a path, so it's staged in a temp
    /// file for the one call. simctl writes its refusal ("Unable to lookup
    /// app", "not booted") to the merged output — kept, so the caller sees
    /// why rather than a bare status. One refusal is common enough to
    /// name: `UNErrorDomain` 2003, "Source is not authorized" (measured,
    /// iOS 27), which is the app's notification permission, not a fault.
    func deliver(_ notification: RemoteNotification) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-notification-\(UUID().uuidString).json")
        try notification.payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (status, output) = try await capture(
            of: xcrun,
            arguments: notification.deliverArguments(udid: udid, deviceSetPath: deviceSetPath, payloadFile: file)
        )
        guard status == 0 else {
            let message = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("Source is not authorized") {
                throw AppsError.notificationsNotAllowed(app: notification.app)
            }
            throw AppsError.deliverFailed(status: status, message: message)
        }
    }

    func terminate(bundleID: String) async throws {
        let status = try await exitStatus(
            of: xcrun, arguments: ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["terminate", udid, bundleID])
        // 3 is simctl's "found nothing to terminate" (Xcode 27): the app
        // is already not running, which is what the caller asked for.
        guard status == 0 || status == 3 else { throw AppsError.terminateFailed(status: status) }
    }

    /// simctl gives a launched app `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` *in
    /// place of* the device-wide `DYLD_INSERT_LIBRARIES` (measured, Xcode
    /// 27), so the list handed over is the whole list, armed ones included.
    /// `env` sets it for simctl alone, not for baguette.
    func launch(bundleID: String) async throws {
        let launch = ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["launch", udid, bundleID]
        let loaded = try await libraries()
        let status = loaded.isEmpty
            ? try await exitStatus(of: xcrun, arguments: launch)
            : try await exitStatus(of: env, arguments: [
                "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(loaded.environmentValue)", xcrun.path,
            ] + launch)
        guard status == 0 else { throw AppsError.launchFailed(status: status) }
    }

    func installed() async throws -> [InstalledApp] {
        let (status, output) = try await capture(
            of: xcrun, arguments: ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["listapps", udid]
        )
        guard status == 0 else { throw AppsError.listFailed(status: status) }

        // listapps names the apps but not their URL schemes, so each
        // app's own Info.plist supplies those. An app whose bundle has
        // gone missing keeps its roster entry and simply contributes no
        // completions — one unreadable bundle shouldn't empty the list.
        return InstalledApp.all(fromListApps: output).map { app in
            guard let bundle = app.bundlePath,
                  let plist = try? Data(
                      contentsOf: bundle.appendingPathComponent("Info.plist")
                  )
            else { return app }
            return app.withSchemes(InstalledApp.schemes(inInfoPlist: plist))
        }
    }

    /// Accumulates a child's stdout across arbitrarily-chunked callbacks
    /// that may land on any queue.
    private final class ByteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            bytes.append(chunk)
        }

        func collected() -> Data {
            lock.lock(); defer { lock.unlock() }
            return bytes
        }
    }

    /// Run a one-shot child to completion and hand back its exit status
    /// *and* everything it wrote. `listapps` answers on stdout rather
    /// than through its exit code, and its output arrives in whatever
    /// chunks the pipe delivers — so the bytes are accumulated whole and
    /// parsed once at exit, never per chunk.
    private func capture(
        of executable: URL, arguments: [String]
    ) async throws -> (Int32, Data) {
        let buffer = ByteBox()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int32, Data), Error>) in
            do {
                try subprocess.run(
                    executable: executable,
                    arguments: arguments,
                    onBytes: { buffer.append($0) },
                    onExit: { continuation.resume(returning: ($0, buffer.collected())) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Total bytes of regular files under `root` — what the archive
    /// actually inflated to on disk.
    private static func regularFileBytes(under root: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Run a one-shot child to completion and hand back its exit
    /// status. Output is discarded — both verbs speak through their
    /// exit code alone.
    private func exitStatus(of executable: URL, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try subprocess.run(
                    executable: executable,
                    arguments: arguments,
                    onBytes: { _ in },
                    onExit: { continuation.resume(returning: $0) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
