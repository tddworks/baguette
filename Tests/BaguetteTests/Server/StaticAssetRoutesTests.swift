import Foundation
import Testing

@testable import Baguette

/// The static UI lives in subfolders under `Resources/Web/` (`farm/`,
/// `baguette/gestures/`, `sim-list/`, …) and Hummingbird needs one
/// literal route per subdirectory (two placeholder routes sharing a
/// path slot with different param names are rejected). That route
/// table is data — `Server.staticAssetSubdirectories` — and this
/// suite pins it against the web root on disk so adding a new
/// subfolder without routing it fails a test instead of 404ing in
/// the browser (as `sim-list/device-filter.js` once did).
@Suite("Server static asset routes")
struct StaticAssetRoutesTests {

    @Test func `every file-bearing web-root subdirectory is routable`() throws {
        let webRoot = Self.sourceWebRoot()
        let onDisk = try Self.fileBearingSubdirectories(of: webRoot)
        #expect(!onDisk.isEmpty)
        for dir in onDisk {
            #expect(
                Server.staticAssetSubdirectories.contains(dir),
                "Resources/Web/\(dir)/ has assets but no /\(dir)/:file route"
            )
        }
    }

    @Test func `routable subdirectories all exist on disk`() throws {
        let webRoot = Self.sourceWebRoot()
        for dir in Server.staticAssetSubdirectories {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: webRoot.appendingPathComponent(dir).path, isDirectory: &isDir
            )
            #expect(exists && isDir.boolValue, "route /\(dir)/:file points at a missing folder")
        }
    }

    // MARK: - helpers

    /// `Tests/BaguetteTests/Server/<this file>` → repo root →
    /// `Sources/Baguette/Resources/Web`.
    private static func sourceWebRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Server/
            .deletingLastPathComponent()  // BaguetteTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Baguette/Resources/Web")
    }

    /// Relative paths of every subdirectory that directly contains at
    /// least one file (directories that only hold other directories,
    /// like `vendor/`, need no route of their own).
    private static func fileBearingSubdirectories(of root: URL) throws -> Set<String> {
        var result = Set<String>()
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            let parent = url.deletingLastPathComponent().path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !parent.isEmpty { result.insert(parent) }
        }
        return result
    }
}
