import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("BakeryRef")
struct BakeryRefTests {

    // MARK: - owner/repo shorthand

    @Test func `should default an owner/repo reference to github over https`() throws {
        let ref = try BakeryRef.parse("tddworks/baguette-plugins")
        #expect(ref.host == "github.com")
        #expect(ref.owner == "tddworks")
        #expect(ref.repo == "baguette-plugins")
        #expect(ref.plugin == nil)
        #expect(ref.cloneURL == "https://github.com/tddworks/baguette-plugins.git")
    }

    @Test func `should take a third segment as the plugin inside the bakery`() throws {
        let ref = try BakeryRef.parse("tddworks/baguette-plugins/a11y")
        #expect(ref.owner == "tddworks")
        #expect(ref.repo == "baguette-plugins")
        #expect(ref.plugin == "a11y")
    }

    @Test func `should drop a trailing .git from the repo segment`() throws {
        let ref = try BakeryRef.parse("tddworks/baguette-plugins.git")
        #expect(ref.repo == "baguette-plugins")
        #expect(ref.cloneURL == "https://github.com/tddworks/baguette-plugins.git")
    }

    @Test func `should accept the github: prefix as an explicit host`() throws {
        let ref = try BakeryRef.parse("github:acme/tools")
        #expect(ref.host == "github.com")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
    }

    // MARK: - full URLs (any host)

    @Test func `should keep the host of an https URL reference`() throws {
        let ref = try BakeryRef.parse("https://gitlab.com/acme/tools")
        #expect(ref.host == "gitlab.com")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
        #expect(ref.cloneURL == "https://gitlab.com/acme/tools.git")
    }

    @Test func `should keep an explicit port in the clone URL`() throws {
        // A self-hosted git on a non-default port is a normal
        // enterprise setup. Dropping the port sends `git clone` to
        // whatever answers on 443 instead — a different host as far as
        // the user is concerned.
        let ref = try BakeryRef.parse("https://git.example:8443/acme/tools")
        #expect(ref.host == "git.example")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
        #expect(ref.cloneURL == "https://git.example:8443/acme/tools.git")
    }

    @Test func `should clone a plain-http reference over http`() throws {
        // `parse` accepts http:// as a form, so rewriting it to https
        // is a silent substitution, not a policy — a self-hosted git
        // that only speaks http would fail with a TLS error naming a
        // scheme the user never typed.
        let ref = try BakeryRef.parse("http://git.internal:8080/acme/tools")
        #expect(ref.cloneURL == "http://git.internal:8080/acme/tools.git")
    }

    @Test func `should keep one cache directory per host whatever the port`() throws {
        // The port disambiguates nothing on disk — `git.example` is one
        // source whether it's reached on 443 or 8443 — and a colon in a
        // path component is asking for trouble.
        let ref = try BakeryRef.parse("https://git.example:8443/acme/tools")
        #expect(ref.cacheSubpath == "git.example/acme/tools")
    }

    @Test func `should understand an scp-style git URL reference`() throws {
        // `git@github.com:owner/repo.git` — the form GitHub prints for
        // SSH remotes. Kept verbatim as the clone URL so a user's SSH
        // keys carry through for private bakeries.
        let ref = try BakeryRef.parse("git@github.com:acme/tools.git")
        #expect(ref.host == "github.com")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
        #expect(ref.cloneURL == "git@github.com:acme/tools.git")
    }

    @Test func `should treat a file URL as a local, host-less bakery`() throws {
        // The reproducible test path and a handy way to develop a
        // bakery against a checkout without pushing.
        let ref = try BakeryRef.parse("file:///Users/me/my-bakery")
        #expect(ref.host == "")
        #expect(ref.repo == "my-bakery")
        #expect(ref.cloneURL == "file:///Users/me/my-bakery")
    }

    // MARK: - identity + cache location

    @Test func `should see two references to the same repo as one bakery whatever plugin they name`() throws {
        // The bakery is the repo; the plugin segment only picks what to
        // install. Adding the source is the same act either way.
        let bare = try BakeryRef.parse("acme/tools")
        let scoped = try BakeryRef.parse("acme/tools/hello")
        #expect(bare.bakery == scoped.bakery)
    }

    @Test func `should scope the cache path by host and owner so names can't collide`() throws {
        let a = try BakeryRef.parse("acme/tools")
        let b = try BakeryRef.parse("https://gitlab.com/acme/tools")
        #expect(a.cacheSubpath == "github.com/acme/tools")
        #expect(b.cacheSubpath == "gitlab.com/acme/tools")
        #expect(a.cacheSubpath != b.cacheSubpath)
    }

    // MARK: - rejections

    @Test func `should reject an empty bakery reference`() throws {
        #expect(throws: BakeryRefError.empty) { try BakeryRef.parse("   ") }
    }

    @Test func `should reject a bare word with no owner`() throws {
        #expect(throws: BakeryRefError.malformed(reference: "justaname")) {
            try BakeryRef.parse("justaname")
        }
    }

    @Test func `should reject a shorthand reference with too many segments`() throws {
        #expect(throws: BakeryRefError.malformed(reference: "a/b/c/d")) {
            try BakeryRef.parse("a/b/c/d")
        }
    }
}
