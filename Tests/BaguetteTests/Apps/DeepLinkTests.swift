import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `DeepLink` — what a developer means when they
/// type a URL into the console and expect it to land in their app.
///
/// The load-bearing behaviour is the routing verdict. A custom scheme
/// (`myapp://…`) reaches the app that registered it, but an `https://…`
/// universal link is handed to Safari by the simulator rather than the
/// app — long-standing simulator behaviour that every existing tool
/// (`simctl openurl`, `idb open`, Maestro's `openLink`) performs
/// silently. Modelling the verdict as a value lets the console warn
/// *before* dispatch instead of leaving the developer to wonder why
/// Safari opened.
@Suite("DeepLink")
struct DeepLinkTests {

    @Test func `should route a custom scheme link to the app that registered it`() {
        let link = DeepLink.from("myapp://profile/42")
        #expect(link?.scheme == "myapp")
        #expect(link?.routing == .app)
    }

    @Test func `should route an https link to the browser, not the app`() {
        let link = DeepLink.from("https://example.com/profile/42")
        #expect(link?.scheme == "https")
        #expect(link?.routing == .browser)
    }

    @Test func `should route an http link to the browser too`() {
        #expect(DeepLink.from("http://example.com")?.routing == .browser)
    }

    @Test func `should normalise a link scheme to lower case`() {
        let link = DeepLink.from("MyApp://Profile")
        #expect(link?.scheme == "myapp")
        #expect(link?.routing == .app)
    }

    @Test func `should trim whitespace around a pasted link`() {
        #expect(DeepLink.from("  myapp://profile\n")?.scheme == "myapp")
    }

    @Test func `should not treat a bare word as a deep link`() {
        #expect(DeepLink.from("profile") == nil)
    }

    @Test func `should not treat blank input as a deep link`() {
        #expect(DeepLink.from("   ") == nil)
    }

    @Test func `should open a deep link with simctl openurl on the device`() {
        let link = DeepLink.from("myapp://profile/42")
        #expect(link?.openArguments(udid: "U") == ["simctl", "openurl", "U", "myapp://profile/42"])
    }

    @Test func `should open a deep link inside the device's custom device set when it lives in one`() {
        let link = DeepLink.from("myapp://profile/42")
        #expect(link?.openArguments(udid: "U", deviceSetPath: "/custom set")
            == ["simctl", "--set", "/custom set", "openurl", "U", "myapp://profile/42"])
    }
}
