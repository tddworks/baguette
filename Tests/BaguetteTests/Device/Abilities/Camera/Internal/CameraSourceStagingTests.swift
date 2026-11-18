import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("CameraSourceStaging")
@MainActor
struct CameraSourceStagingTests {

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("camstage-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStaging() -> CameraSourceStaging {
        CameraSourceStaging(root: makeRoot())
    }

    @Test func `should store an uploaded camera source and expose its host path`() async throws {
        let staging = makeStaging()
        let url = try await staging.stage(udid: "U", filename: "pic.png", data: Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(staging.path(udid: "U") == url.path)
        await staging.clear(udid: "U")
    }

    @Test func `should replace the previously staged file when a new one is uploaded`() async throws {
        let staging = makeStaging()
        let first = try await staging.stage(udid: "U", filename: "a.png", data: Data([1]))
        let second = try await staging.stage(udid: "U", filename: "b.mp4", data: Data([2]))
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(staging.path(udid: "U") == second.path)
        await staging.clear(udid: "U")
    }

    @Test func `should delete the staged file and forget its path when cleared`() async throws {
        let staging = makeStaging()
        let url = try await staging.stage(udid: "U", filename: "pic.png", data: Data([1]))
        await staging.clear(udid: "U")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(staging.path(udid: "U") == nil)
    }

    @Test func `should stage each simulator's upload in its own slot`() async throws {
        let staging = makeStaging()
        _ = try await staging.stage(udid: "A", filename: "a.png", data: Data([1]))
        _ = try await staging.stage(udid: "B", filename: "b.png", data: Data([2]))
        #expect(staging.path(udid: "A") != nil)
        #expect(staging.path(udid: "B") != nil)
        #expect(staging.path(udid: "A") != staging.path(udid: "B"))
        await staging.clear(udid: "A")
        await staging.clear(udid: "B")
    }

    @Test func `should keep only the last component of a path-traversal filename`() async throws {
        let staging = makeStaging()
        let url = try await staging.stage(udid: "U", filename: "../../etc/evil.png", data: Data([1]))
        #expect(url.lastPathComponent == "evil.png")
        await staging.clear(udid: "U")
    }

    // MARK: - Slot containment

    /// The udid is percent-decoded off the request path, so it can carry
    /// a real `..`. Staging hands its slot directory to a *recursive*
    /// removal on every upload, so a udid that isn't slot-shaped has to
    /// be refused outright rather than deleting someone else's tree.
    @Test func `should refuse an upload and touch nothing when the udid escapes the staging root`() async throws {
        let root = makeRoot()
        let staging = CameraSourceStaging(root: root)

        // A real directory next to the root, holding a file — staging
        // deletes-then-recreates its slot, so only the *contents* prove
        // whether the recursive removal reached outside the root.
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("camstage-bystander-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let precious = sibling.appendingPathComponent("precious.txt")
        try Data([9]).write(to: precious)

        let escape = "../\(sibling.lastPathComponent)"
        await #expect(throws: (any Error).self) {
            try await staging.stage(udid: escape, filename: "evil.png", data: Data([1]))
        }
        #expect(FileManager.default.fileExists(atPath: precious.path), "the bystander must survive")
        #expect(staging.path(udid: escape) == nil)
    }

    @Test func `should remove nothing when clearing a udid that escapes the staging root`() async throws {
        let root = makeRoot()
        let staging = CameraSourceStaging(root: root)

        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("camstage-bystander-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let precious = sibling.appendingPathComponent("precious.txt")
        try Data([9]).write(to: precious)

        await staging.clear(udid: "../\(sibling.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: precious.path), "the bystander must survive")
    }

    @Test func `should refuse an upload when the udid is empty`() async {
        let staging = makeStaging()
        await #expect(throws: (any Error).self) {
            try await staging.stage(udid: "", filename: "pic.png", data: Data([1]))
        }
    }
}
