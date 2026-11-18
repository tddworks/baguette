import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Whether a browser's install request may be served at all.
///
/// This is the boundary that lets the browser install anything. The
/// page names a bakery by its **recorded id**, never a URL — so the
/// worst a request that got past the origin checks can do is install
/// from a source the user already trusted in a terminal, at the commit
/// they pinned. Every refusal path is covered here because a hole in
/// one turns a browser route into "clone anything and put it on disk".
@Suite("InstallDecision")
struct InstallDecisionTests {

    @Test func `should allow installing a plugin its trusted bakery offers`() {
        let decision = InstallDecision.decide(
            bakery: "github.com/acme/tools", plugin: "hello", among: [Self.tools]
        )
        #expect(decision == .install(Self.tools, plugin: "hello"))
    }

    @Test func `should refuse a bakery that was never trusted`() {
        // The whole point: the id has to already be in bakeries.json.
        // A page naming a source the user never accepted gets nothing,
        // and nothing is cloned to find out.
        let decision = InstallDecision.decide(
            bakery: "github.com/evil/pack", plugin: "hello", among: [Self.tools]
        )
        #expect(decision == .notTrusted(bakery: "github.com/evil/pack"))
    }

    @Test func `should refuse everything when no bakery is trusted`() {
        #expect(InstallDecision.decide(bakery: "github.com/acme/tools", plugin: "hello", among: [])
                == .notTrusted(bakery: "github.com/acme/tools"))
    }

    @Test func `should refuse a plugin the bakery does not offer`() {
        // Trusting a bakery is not trusting an arbitrary path inside
        // it — only the names its recorded menu lists.
        let decision = InstallDecision.decide(
            bakery: "github.com/acme/tools", plugin: "not-on-the-menu", among: [Self.tools]
        )
        #expect(decision == .notOffered(plugin: "not-on-the-menu", by: Self.tools))
    }

    @Test func `should refuse an empty plugin name rather than resolve it`() {
        // A missing field in the request body arrives as "", and an
        // empty name must never fall through to "install the only one".
        #expect(InstallDecision.decide(bakery: "github.com/acme/tools", plugin: "", among: [Self.tools])
                == .notOffered(plugin: "", by: Self.tools))
    }

    @Test func `should say what was wrong in each refusal without echoing back what was asked for`() {
        // The message reaches a browser modal. It names the bakery the
        // user trusted and what it offers — both already theirs — and
        // never reflects an unknown id into the page.
        let untrusted = InstallDecision.decide(
            bakery: "github.com/evil/pack", plugin: "hello", among: [Self.tools]
        )
        #expect(untrusted.refusal?.contains("evil") == false)
        #expect(untrusted.refusal?.contains("bakery add") == true)

        let missing = InstallDecision.decide(
            bakery: "github.com/acme/tools", plugin: "nope", among: [Self.tools]
        )
        #expect(missing.refusal?.contains("hello") == true)
        #expect(InstallDecision.install(Self.tools, plugin: "hello").refusal == nil)
    }

    static let tools = Bakery(
        id: "github.com/acme/tools", url: "https://github.com/acme/tools.git",
        commit: "c0ffee", plugins: ["hello", "goodbye"], addedAt: "2026-08-19T00:00:00Z"
    )
}
