import Testing
import Foundation
@testable import Baguette

@Suite("RecordingsDirectory")
struct RecordingsDirectoryTests {

    @Test func `newOutputURL embeds udid and uses the format extension`() {
        let url = RecordingsDirectory.newOutputURL(udid: "ABC-123", format: .mp4)
        #expect(url.lastPathComponent.hasPrefix("ABC-123-"))
        #expect(url.pathExtension == "mp4")
        #expect(url.path.contains("/ABC-123/"))
    }

    @Test func `resolve rejects path traversal segments`() {
        #expect(RecordingsDirectory.resolve(udid: "abc", filename: "../../etc/passwd") == nil)
        #expect(RecordingsDirectory.resolve(udid: "abc", filename: "sub/file.mp4") == nil)
    }

    @Test func `resolve rejects empty udid or filename`() {
        #expect(RecordingsDirectory.resolve(udid: "", filename: "x.mp4") == nil)
        #expect(RecordingsDirectory.resolve(udid: "abc", filename: "") == nil)
    }

    @Test func `resolve returns nil for a missing file`() {
        #expect(RecordingsDirectory.resolve(udid: "no-such-udid", filename: "ghost.mp4") == nil)
    }

    @Test func `resolve returns the URL for an existing file under the udid subtree`() throws {
        let udid = "T-\(UUID().uuidString)"
        let dir = RecordingsDirectory.root.appendingPathComponent(udid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("clip.mp4")
        try Data([0x00, 0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = RecordingsDirectory.resolve(udid: udid, filename: "clip.mp4")
        #expect(resolved?.path == file.path)
    }
}
