import BaguetteDevice
import Foundation

/// One completion offered by the console's URL bar: a scheme an
/// installed app answers to, plus the app it belongs to so the
/// suggestion row can say whose scheme it is.
///
/// Ranking is the whole job. A single app commonly registers a readable
/// scheme, a reverse-DNS alias, and a tool-injected dev-client scheme —
/// three entries for one app, of which only the first is what a
/// developer means to type. Unranked, the useful suggestion sits
/// wherever dictionary iteration puts it. So matches are ordered:
/// schemes *starting* with what was typed before ones merely containing
/// it, then an app's own scheme before its aliases, then alphabetically
/// so the list never reshuffles between keystrokes.
public struct SchemeSuggestion: Equatable, Sendable {
    public let scheme: String
    public let appName: String
    public let bundleIdentifier: String

    /// What the bar completes to — the scheme plus `://`, ready for a
    /// path to be typed after it.
    public var completion: String { "\(scheme)://" }

    /// How much of an alias a scheme looks like. An app's own scheme is
    /// a plain word; a reverse-DNS alias carries dots; a dev-client
    /// scheme injected by tooling carries a `+`.
    private enum Style: Int {
        case own = 0, reverseDNS = 1, injected = 2

        init(_ scheme: String) {
            if scheme.contains("+") { self = .injected }
            else if scheme.contains(".") { self = .reverseDNS }
            else { self = .own }
        }
    }

    /// Suggestions for what's been typed so far. An empty query offers
    /// everything — that's the "what can I even open here?" case, and
    /// showing the full ranked inventory answers it.
    public static func matching(_ query: String, in apps: [InstalledApp]) -> [SchemeSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return apps
            .flatMap { app in
                app.schemes.map {
                    SchemeSuggestion(
                        scheme: $0, appName: app.name, bundleIdentifier: app.bundleIdentifier
                    )
                }
            }
            .filter { needle.isEmpty || $0.scheme.contains(needle) }
            .sorted { a, b in
                let (aKey, bKey) = (a.rank(for: needle), b.rank(for: needle))
                return aKey < bKey
            }
    }

    /// Sort key: prefix matches first, then an app's own scheme over its
    /// aliases, then alphabetical for a stable list.
    private func rank(for needle: String) -> SortKey {
        SortKey(
            prefix: scheme.hasPrefix(needle) ? 0 : 1,
            style: Style(scheme).rawValue,
            scheme: scheme
        )
    }

    private struct SortKey: Comparable {
        let prefix: Int
        let style: Int
        let scheme: String

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            (lhs.prefix, lhs.style, lhs.scheme) < (rhs.prefix, rhs.style, rhs.scheme)
        }
    }
}
