import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// The refusal paths on the distribution side.
///
/// A bakery reference is the first thing a user types and the last thing
/// they'd think to check, so the parser's "no" cases matter more than the
/// happy path — a reference that half-parses would clone something the
/// user didn't ask for.
@Suite("Bakery refusals")
struct BakeryEdgeCaseTests {

    // MARK: - references

    @Test func `should refuse an https bakery reference with no repository path`() {
        // A host on its own names no repo to clone.
        #expect(throws: BakeryRefError.malformed(reference: "https://github.com")) {
            _ = try BakeryRef.parse("https://github.com")
        }
        #expect(throws: BakeryRefError.malformed(reference: "https://github.com/tddworks")) {
            _ = try BakeryRef.parse("https://github.com/tddworks")
        }
    }

    @Test func `should refuse an https bakery reference that isn't a URL at all`() {
        #expect(throws: (any Error).self) {
            _ = try BakeryRef.parse("https://")
        }
    }

    @Test func `should refuse an scp-style bakery reference with no colon`() {
        // `git@host:owner/repo.git` — without the colon there's no path.
        #expect(throws: BakeryRefError.malformed(reference: "git@github.com")) {
            _ = try BakeryRef.parse("git@github.com")
        }
    }

    @Test func `should refuse an scp-style bakery reference with no owner and repo`() {
        #expect(throws: BakeryRefError.malformed(reference: "git@github.com:tddworks")) {
            _ = try BakeryRef.parse("git@github.com:tddworks")
        }
    }

    // MARK: - menus

    @Test func `should refuse a bakery menu that isn't JSON`() {
        #expect(throws: BakeryMenuError.malformedJSON) {
            _ = try BakeryMenu.parsing(json: Data("# a readme, not a menu".utf8))
        }
    }

    @Test func `should refuse a bakery menu that is JSON but not an object`() {
        #expect(throws: BakeryMenuError.malformedJSON) {
            _ = try BakeryMenu.parsing(json: Data(#"["a11y"]"#.utf8))
        }
    }

    // MARK: - installing by bare name

    @Test func `should refuse installing a name when two trusted bakeries both offer it`() async throws {
        // Ambiguity is the user's to resolve: silently picking the first
        // would install code from a source they didn't mean to prefer.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bakery-ambiguous-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = FileSystemBakeries(home: home)
        try registry.record(Bakery(
            id: "github.com/one/plugins", url: "one/plugins",
            commit: "aaa", plugins: ["a11y"], addedAt: "2026-01-01T00:00:00Z"
        ))
        try registry.record(Bakery(
            id: "github.com/two/plugins", url: "two/plugins",
            commit: "bbb", plugins: ["a11y"], addedAt: "2026-01-02T00:00:00Z"
        ))

        let install = BakeryInstall(checkout: MockCheckout(), home: home)

        await #expect(throws: BakeryResolveError.ambiguous(
            name: "a11y",
            bakeries: ["github.com/one/plugins", "github.com/two/plugins"]
        )) {
            try await install.installByName("a11y")
        }
    }

    @Test func `should refuse installing a name when no trusted bakery offers it`() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bakery-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let install = BakeryInstall(checkout: MockCheckout(), home: home)
        await #expect(throws: BakeryResolveError.notOffered(name: "a11y")) {
            try await install.installByName("a11y")
        }
    }

    @Test func `should tell the user how to disambiguate when a plugin name is ambiguous`() {
        // Naming both sources and the qualified spelling, because
        // "ambiguous" alone leaves the user stuck.
        let error = BakeryResolveError.ambiguous(
            name: "a11y", bakeries: ["github.com/one/plugins", "github.com/two/plugins"]
        )
        #expect(error.description.contains("github.com/one/plugins"))
        #expect(error.description.contains("github.com/two/plugins"))
        #expect(error.description.contains("owner/repo/a11y"))
    }
}
