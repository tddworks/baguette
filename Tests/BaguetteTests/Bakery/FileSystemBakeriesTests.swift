import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Round-trip coverage for the `~/.baguette` registry. Roots are
/// injectable so the suite writes into a throwaway temp home, mirroring
/// `FileSystemChromeStore` / `FileSystemPlugins`.
@Suite("FileSystemBakeries")
struct FileSystemBakeriesTests {

    // MARK: - trusted sources

    @Test func `should keep a recorded bakery across a reload`() throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "abc123"))

        let reread = FileSystemBakeries(home: home.url)
        let all = try reread.bakeries()
        #expect(all.map(\.id) == ["github.com/acme/tools"])
        #expect(all.first?.commit == "abc123")
    }

    @Test func `should update a re-recorded bakery in place rather than duplicate it`() throws {
        // Re-adding after an update re-pins the commit rather than
        // stacking a duplicate.
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "old"))
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "new"))

        let all = try registry.bakeries()
        #expect(all.count == 1)
        #expect(all.first?.commit == "new")
    }

    @Test func `should leave the other bakeries when one is forgotten`() throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "a"))
        try registry.record(Self.bakery(id: "github.com/other/pack", commit: "b"))

        try registry.forget(bakeryID: "github.com/acme/tools")
        #expect(try registry.bakeries().map(\.id) == ["github.com/other/pack"])
    }

    @Test func `should read an absent registry as no bakeries rather than an error`() throws {
        // A fresh install has no bakeries.json. That's the normal
        // first-run state, not a failure.
        let home = try TempHome()
        #expect(try FileSystemBakeries(home: home.url).bakeries().isEmpty)
    }

    // MARK: - installed-plugin provenance

    @Test func `should remember an installed plugin's source and commit`() throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.recordInstalled(
            InstalledPlugin(name: "a11y", bakery: "github.com/acme/tools", commit: "abc123")
        )

        let reread = try FileSystemBakeries(home: home.url).installed()
        #expect(reread.first?.name == "a11y")
        #expect(reread.first?.bakery == "github.com/acme/tools")
        #expect(reread.first?.commit == "abc123")
    }

    @Test func `should keep a bakery trusted when a plugin installed from it is forgotten`() throws {
        // Removing a plugin shouldn't forget the bakery it came from,
        // and vice versa — they answer different questions.
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "a"))
        try registry.recordInstalled(
            InstalledPlugin(name: "a11y", bakery: "github.com/acme/tools", commit: "a")
        )

        try registry.forgetInstalled(name: "a11y")
        #expect(try registry.installed().isEmpty)
        #expect(try registry.bakeries().count == 1)
    }

    // MARK: - a registry that can't be read

    @Test func `should report an unreadable registry as an error rather than an empty one`() throws {
        // The difference matters because the next `record` writes back
        // what it just read: reporting "no bakeries" for a file that is
        // merely unreadable would erase every trusted source and the
        // whole installed-plugin provenance on the following write.
        //
        // A directory where the file belongs is the portable way to
        // make the path exist and the read fail — a permissions error
        // reads identically to the caller.
        let home = try TempHome()
        try FileManager.default.createDirectory(
            at: home.url.appendingPathComponent("bakeries.json"),
            withIntermediateDirectories: true
        )
        let registry = FileSystemBakeries(home: home.url)

        #expect(throws: (any Error).self) { _ = try registry.bakeries() }
    }

    @Test func `should read a missing registry as no bakeries and no installed plugins`() throws {
        // First run has neither file, and that is not an error.
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        #expect(try registry.bakeries().isEmpty)
        #expect(try registry.installed().isEmpty)
    }

    // MARK: - concurrent writers

    @Test func `should keep every bakery recorded concurrently`() async throws {
        // Every mutator is a read-modify-write over the whole file, and
        // Hummingbird serves requests concurrently — two overlapping
        // installs would otherwise both read the old array, and the
        // second write would drop the first. `.atomic` prevents a torn
        // file; it does not prevent a lost update.
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try? registry.record(
                        Self.bakery(id: "github.com/acme/pack-\(index)", commit: "c\(index)")
                    )
                }
            }
        }

        #expect(try registry.bakeries().count == 16)
    }

    @Test func `should keep every installed plugin recorded concurrently`() async throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try? registry.recordInstalled(
                        InstalledPlugin(
                            name: "plugin-\(index)",
                            bakery: "github.com/acme/tools",
                            commit: "c\(index)"
                        )
                    )
                }
            }
        }

        #expect(try registry.installed().count == 16)
    }

    // MARK: - helpers

    static func bakery(id: String, commit: String) -> Bakery {
        Bakery(
            id: id, url: "https://\(id).git", commit: commit,
            plugins: ["a11y"], addedAt: "2026-07-23T00:00:00Z"
        )
    }

    final class TempHome {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }
}
