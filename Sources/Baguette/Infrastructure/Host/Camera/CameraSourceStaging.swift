import Foundation

/// The host-side landing spot for a browser-uploaded camera source.
/// Unlike the `/files` upload (which `simctl` consumes synchronously
/// inside the request), a camera source must *outlive* its POST so the
/// camera WebSocket can stream from it later — so it's staged into a
/// persistent per-udid directory and remembered here, keyed by udid.
/// The camera WS resolves the staged path on `camera_start` and clears
/// the slot on teardown, so the browser never sends a filesystem path
/// across the wire.
///
/// `@MainActor` because both the upload route and the camera WS handler
/// touch the `staged` map from that isolation. The filesystem work
/// deliberately does *not* run there: an upload is capped at
/// `maxUploadBytes` (1 GiB), and MainActor is the same thread the Indigo
/// HID input path has to run on — a multi-hundred-megabyte write would
/// stall gestures for every other page connected to the server.
@MainActor
final class CameraSourceStaging {
    static let shared = CameraSourceStaging()

    private let root: URL
    private var staged: [String: URL] = [:]

    init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("baguette-camera-source", isDirectory: true)) {
        self.root = root
    }

    /// Stage `data` for `udid`, replacing any file previously staged for
    /// it, and return the host path.
    ///
    /// Both names are attacker-shaped: `filename` is a query parameter
    /// and `udid` is a percent-decoded path segment. The filename is
    /// reduced to its last path component, and the udid must name a
    /// `CameraSourceSlot` — otherwise it could walk the slot directory
    /// out of `root` and take the recursive delete below with it.
    @discardableResult
    func stage(udid: String, filename: String, data: Data) async throws -> URL {
        guard let slot = CameraSourceSlot(udid: udid) else {
            throw CameraSourceStagingError.unusableSlot(udid)
        }
        let leaf = (filename as NSString).lastPathComponent
        let name = leaf.isEmpty ? "source" : leaf
        let dir = root.appendingPathComponent(slot.name, isDirectory: true)
        let dest = dir.appendingPathComponent(name)

        try await Self.write(data, to: dest, replacing: dir)
        staged[udid] = dest
        return dest
    }

    /// The staged host path for `udid`, or `nil` if nothing is staged.
    func path(udid: String) -> String? {
        staged[udid]?.path
    }

    /// Drop the staged file (and its slot directory) for `udid`. A udid
    /// with no slot never staged anything, so there's nothing to remove.
    func clear(udid: String) async {
        staged[udid] = nil
        guard let slot = CameraSourceSlot(udid: udid) else { return }
        let dir = root.appendingPathComponent(slot.name, isDirectory: true)
        await Self.remove(dir)
    }

    // MARK: - Off-actor filesystem work

    /// Replace `dir` with a fresh one holding `data` at `dest`.
    /// `nonisolated` + `Task.detached` so the write lands on the
    /// concurrent executor rather than blocking MainActor.
    private nonisolated static func write(
        _ data: Data, to dest: URL, replacing dir: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dest)
        }.value
    }

    private nonisolated static func remove(_ dir: URL) async {
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: dir)
        }.value
    }
}

enum CameraSourceStagingError: LocalizedError, Equatable, CustomStringConvertible {
    case unusableSlot(String)

    var description: String {
        switch self {
        case .unusableSlot(let udid):
            return "camera source: '\(udid)' is not a usable simulator udid"
        }
    }

    var errorDescription: String? { description }
}
