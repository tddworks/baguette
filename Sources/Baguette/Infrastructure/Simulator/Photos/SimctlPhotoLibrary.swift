import Foundation

/// `PhotoLibrary` backed by `xcrun simctl addmedia <udid> <path>`.
///
/// The orchestration here is pure: argv assembly (delegated to
/// `MediaItem.addMediaArguments`) + the `Subprocess` exit handshake.
/// The `Foundation.Process` plumbing lives in `HostSubprocess` (already
/// vendored for `LogStream`), so this file is unit-covered end-to-end
/// via `MockSubprocess` — only the real spawn is integration-only.
final class SimctlPhotoLibrary: PhotoLibrary, @unchecked Sendable {
    private let udid: String
    private let deviceSetPath: String?
    private let subprocess: any Subprocess
    private let xcrun: URL

    init(
        udid: String,
        deviceSetPath: String? = nil,
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
        self.subprocess = subprocess
        self.xcrun = xcrun
    }

    func add(_ media: MediaItem) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: media.addMediaArguments(udid: udid, deviceSetPath: deviceSetPath),
                    onBytes: { _ in },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: PhotoLibraryError.addFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
