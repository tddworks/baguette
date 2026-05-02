import Testing
import Foundation
@testable import Baguette

/// `WebRoot` resolves nested asset paths (e.g. `farm/farm.html`) so the
/// device-farm UI can live in its own subfolder under `Resources/Web/`
/// instead of bloating the flat root. These tests pin the lookup
/// behavior so a future refactor of `Bundle.url(forResource:…)` or the
/// source-tree fallback can't silently break the `/farm` route.
@Suite("WebRoot subdirectory lookup")
struct WebRootSubdirTests {

    @Test("resolves a file in a subdirectory via BAGUETTE_WEB_DIR")
    func resolvesNestedPathViaEnvOverride() throws {
        let tmp = try makeTempWebTree(files: [
            "farm/farm.html": "<!doctype html><title>farm</title>",
            "farm/farm.css":  "body{}",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        setenv("BAGUETTE_WEB_DIR", tmp.path, 1)
        defer { unsetenv("BAGUETTE_WEB_DIR") }

        let html = WebRoot.string(named: "farm/farm.html")
        let css  = WebRoot.string(named: "farm/farm.css")
        #expect(html?.contains("<title>farm</title>") == true)
        #expect(css == "body{}")
    }

    @Test("returns nil for a missing nested file")
    func returnsNilWhenMissing() throws {
        let tmp = try makeTempWebTree(files: [:])
        defer { try? FileManager.default.removeItem(at: tmp) }

        setenv("BAGUETTE_WEB_DIR", tmp.path, 1)
        defer { unsetenv("BAGUETTE_WEB_DIR") }

        #expect(WebRoot.data(named: "farm/does-not-exist.js") == nil)
    }

    // MARK: - helpers

    private func makeTempWebTree(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-webroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
