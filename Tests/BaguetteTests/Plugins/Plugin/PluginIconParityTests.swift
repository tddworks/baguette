import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The icon set exists twice — `PluginIcon` here, the `ICONS` map in
/// `page/internal/plugins/plugins-rail.js` — and until this suite nothing checked they agreed.
///
/// The duplication is deliberate and not removable: the Swift side is
/// the parse boundary that stops manifest text reaching the DOM, and the
/// JS side holds the actual SVG paths, which have no business in a Swift
/// enum. What *was* removable is the failure mode. The two files carried
/// a comment asking a human to keep them in sync, and a comment is not a
/// mechanism: adding a case to one and forgetting the other ships a
/// plugin that passes `baguette plugin validate` and then draws the
/// wrong glyph, which nothing would have caught.
///
/// Reading in this direction on purpose — `allCases` is exact, so only
/// the JS half needs parsing, and a regex is applied to the file that
/// can afford one.
@Suite("PluginIcon parity")
struct PluginIconParityTests {

    private static var simPluginsJS: URL {
        RepoRoot.url
            .appendingPathComponent("Sources/Baguette/Resources/Web/page/internal/plugins/plugins-rail.js")
    }

    /// The keys of the `ICONS` object literal in `page/internal/plugins/plugins-rail.js`.
    static func iconsDeclaredInJS() throws -> Set<String> {
        let source = try String(contentsOf: simPluginsJS, encoding: .utf8)
        guard let start = source.range(of: "const ICONS = {"),
              let end = source.range(of: "\n  };", range: start.upperBound..<source.endIndex)
        else {
            Issue.record("could not find the ICONS literal in page/internal/plugins/plugins-rail.js")
            return []
        }

        let block = source[start.upperBound..<end.lowerBound]
        var names: Set<String> = []
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `name: '<svg paths>',` — skip comment lines and blanks.
            guard !trimmed.hasPrefix("//"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    @Test func `should let the page draw every glyph a plugin manifest may name`() throws {
        // The direction that actually breaks a user: a manifest names an
        // icon, Swift accepts it as known, and the browser has no path
        // for it — so `iconSVG` silently falls back to `list` and the
        // plugin wears the wrong face with no warning anywhere.
        let swift = Set(PluginIcon.allCases.map(\.rawValue))
        let js = try Self.iconsDeclaredInJS()

        #expect(
            swift.subtracting(js).isEmpty,
            "PluginIcon has cases page/internal/plugins/plugins-rail.js can't draw: \(swift.subtracting(js).sorted())"
        )
    }

    @Test func `should draw no glyph on the page that a plugin manifest could not name`() throws {
        // The other direction is dead weight rather than breakage, but it
        // means a plugin naming that icon gets `puzzle` plus a validate
        // warning while the artwork sits right there unused.
        let swift = Set(PluginIcon.allCases.map(\.rawValue))
        let js = try Self.iconsDeclaredInJS()

        #expect(
            js.subtracting(swift).isEmpty,
            "page/internal/plugins/plugins-rail.js draws glyphs PluginIcon doesn't name: \(js.subtracting(swift).sorted())"
        )
    }

    @Test func `should find the page's full icon set rather than agree about nothing`() throws {
        // Two empty sets are equal. If the regex ever stops matching —
        // the literal is reformatted, renamed, moved — both tests above
        // would pass vacuously and go on passing forever.
        let js = try Self.iconsDeclaredInJS()
        #expect(js.count == PluginIcon.allCases.count)
        #expect(js.contains("puzzle"), "expected the fallback glyph among the parsed names")
    }
}
