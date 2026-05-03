import Foundation

/// Where finished MP4 recordings land on disk. Per-process: each
/// `baguette serve` run owns its own subtree under
/// `<tmp>/baguette-recordings/<pid>/<udid>/`, so a fresh server start
/// can't accidentally serve files left over from a previous session
/// (and clean-up is whatever the OS does to `/tmp`).
enum RecordingsDirectory {

    /// Root directory for this process. Created on demand.
    static let root: URL = {
        let pid = ProcessInfo.processInfo.processIdentifier
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-recordings", isDirectory: true)
            .appendingPathComponent(String(pid), isDirectory: true)
    }()

    /// Build a unique output URL for a new recording on the given udid.
    /// Filename embeds the udid and a millisecond timestamp so files
    /// from concurrent recordings don't collide.
    static func newOutputURL(udid: String, format: RecordingFormat) -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "\(udid)-\(stamp).\(format.fileExtension)"
        return root.appendingPathComponent(udid, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Resolve a (udid, filename) pair into the recording's URL,
    /// rejecting anything that escapes the per-udid directory. Returns
    /// nil for a missing or out-of-tree path.
    static func resolve(udid: String, filename: String) -> URL? {
        guard !udid.isEmpty, !filename.isEmpty,
              !filename.contains("/"), !filename.contains("..") else {
            return nil
        }
        let dir = root.appendingPathComponent(udid, isDirectory: true)
        let url = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
