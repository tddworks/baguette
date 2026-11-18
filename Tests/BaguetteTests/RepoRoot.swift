import Foundation

/// The repository root, found by walking up from this file to `Package.swift`
/// rather than counting folders, so a test can move without its paths breaking.
enum RepoRoot {
    static let url: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }()
}
