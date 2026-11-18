import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("TrustDecision")
struct TrustDecisionTests {

    @Test func `should need no further consent when a bakery is already trusted`() throws {
        // Trust is per bakery, once — installing more from a source you
        // already accepted is friction-free.
        #expect(TrustDecision.decide(alreadyTrusted: true, accepted: false) == .granted)
    }

    @Test func `should grant consent on an explicit acceptance`() throws {
        // `--yes`, or the browser's Install click.
        #expect(TrustDecision.decide(alreadyTrusted: false, accepted: true) == .granted)
    }

    @Test func `should ask before trusting a new bakery`() throws {
        #expect(TrustDecision.decide(alreadyTrusted: false, accepted: false) == .mustAsk)
    }

    @Test func `should name the source and warn what trust means in the trust prompt`() throws {
        let prompt = TrustDecision.prompt(source: "acme/tools", commit: "abc1234")
        #expect(prompt.contains("acme/tools"))
        #expect(prompt.contains("abc1234"))
        // The warning is the whole point: plugins run as real programs.
        #expect(prompt.lowercased().contains("run"))
    }
}
