import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `SchemeSuggestion` — the completion behind
/// the console's URL bar: type a few characters, get the schemes that
/// installed apps actually answer to.
///
/// Ranking carries the weight here. Apps routinely register three or
/// more schemes for one app — a readable one, a reverse-DNS one, and a
/// tool-injected dev-client one — and only the readable scheme is what a
/// developer means to type. Listing them unranked would bury the useful
/// suggestion under noise, so the ordering is a specified behaviour, not
/// an accident of dictionary iteration.
@Suite("SchemeSuggestion")
struct SchemeSuggestionTests {

    private static let apps = [
        InstalledApp(
            bundleIdentifier: "com.example.MyApp",
            name: "My App",
            schemes: ["com.example.myapp", "exp+myapp", "myapp"]
        ),
        InstalledApp(
            bundleIdentifier: "com.example.Other",
            name: "Other",
            schemes: ["othertool"]
        ),
        InstalledApp(
            bundleIdentifier: "com.example.Bare",
            name: "Bare",
            schemes: []
        ),
    ]

    private static func schemes(for prefix: String) -> [String] {
        SchemeSuggestion.matching(prefix, in: apps).map(\.scheme)
    }

    @Test func `should suggest every scheme containing the typed text, the app's own first`() {
        // All three of MyApp's schemes contain "myap"; the readable one
        // is what the developer meant, so it leads and the aliases
        // follow rather than being hidden.
        #expect(Self.schemes(for: "myap") == ["myapp", "com.example.myapp", "exp+myapp"])
    }

    @Test func `should rank a readable scheme above its reverse-DNS twin`() {
        // Both match "com.example.myapp"'s app, but "myapp" is the one a
        // developer means to type.
        let ranked = Self.schemes(for: "")
        #expect(ranked.firstIndex(of: "myapp")! < ranked.firstIndex(of: "com.example.myapp")!)
    }

    @Test func `should rank a tool-injected scheme below the app's own`() {
        let ranked = Self.schemes(for: "")
        #expect(ranked.firstIndex(of: "myapp")! < ranked.firstIndex(of: "exp+myapp")!)
    }

    @Test func `should rank a prefix match above a mid-string match`() {
        // "other" prefixes "othertool"; it only appears mid-string in
        // nothing else here, so add the contrast directly.
        let apps = [
            InstalledApp(bundleIdentifier: "a", name: "A", schemes: ["superapp"]),
            InstalledApp(bundleIdentifier: "b", name: "B", schemes: ["app"]),
        ]
        #expect(SchemeSuggestion.matching("app", in: apps).map(\.scheme) == ["app", "superapp"])
    }

    @Test func `should suggest schemes regardless of the case typed`() {
        #expect(Self.schemes(for: "MYAPP") == ["myapp", "com.example.myapp", "exp+myapp"])
    }

    @Test func `should suggest every scheme when nothing is typed`() {
        #expect(Self.schemes(for: "").count == 4)
    }

    @Test func `should suggest nothing when the typed text matches no scheme`() {
        #expect(Self.schemes(for: "zzz") == [])
    }

    @Test func `should name the app a suggested scheme belongs to`() {
        let suggestion = SchemeSuggestion.matching("myap", in: Self.apps).first
        #expect(suggestion?.appName == "My App")
        #expect(suggestion?.bundleIdentifier == "com.example.MyApp")
    }

    @Test func `should complete a suggestion to a typeable URL prefix`() {
        #expect(SchemeSuggestion.matching("myap", in: Self.apps).first?.completion == "myapp://")
    }
}
