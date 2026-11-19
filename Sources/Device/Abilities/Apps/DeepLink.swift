import Foundation

/// A URL a developer wants to open on a device — what they mean when
/// they type `myapp://profile/42` into the console and expect their app
/// to come to the foreground.
///
/// The value carries a **routing verdict** alongside the URL, because on
/// the simulator the two kinds of link behave differently: a custom
/// scheme reaches the app that registered it, while an `https` universal
/// link is handed to Safari instead. That fallback is silent in every
/// existing tool — `simctl openurl`, `idb open`, Maestro's `openLink` —
/// so a developer testing a universal link watches Safari open and has
/// no idea whether their app, their entitlement, or their
/// apple-app-site-association file is at fault. Naming the verdict here
/// lets the console say so up front.
public struct DeepLink: Equatable, Sendable {

    /// Where the simulator will actually send this link.
    public enum Routing: Equatable, Sendable {
        /// A custom scheme — dispatched to the app that registered it.
        case app
        /// A web scheme — the simulator opens Safari rather than
        /// resolving the associated domain to an installed app.
        case browser
    }

    public let url: URL

    /// The scheme, lower-cased. Schemes are case-insensitive, so this is
    /// the form to match installed apps' registered schemes against.
    public let scheme: String

    private init(url: URL, scheme: String) {
        self.url = url
        self.scheme = scheme
    }

    /// Schemes the simulator hands to Safari instead of an app.
    public static let browserSchemes: Set<String> = ["http", "https"]

    public var routing: Routing {
        Self.browserSchemes.contains(scheme) ? .browser : .app
    }

    /// Read console input as a deep link, or `nil` when it isn't one.
    /// Trims first — console input is very often pasted, arriving with
    /// a trailing newline or leading spaces.
    public static func from(_ text: String) -> DeepLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty
        else { return nil }
        return DeepLink(url: url, scheme: scheme)
    }

    /// The argv tail handed to `xcrun simctl [--set <set>] openurl <udid> <url>`.
    public func openArguments(udid: String, deviceSetPath: String? = nil) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["openurl", udid, url.absoluteString]
    }
}
