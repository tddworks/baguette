import BaguetteDevice
import Foundation

/// Whether a browser's install request may be served — the pure
/// decision behind `POST /bakeries/install`.
///
/// Sibling of `TrustDecision`, and deliberately a different question.
/// `TrustDecision` asks "must we ask the user about this source?";
/// this asks "may this request touch the disk at all?", and the answer
/// is yes only for a source the user *already* trusted from a terminal.
///
/// The request names a bakery by its **recorded id**, never a URL or a
/// git ref. That is the whole safety property: installing writes files
/// baguette later executes, and the only thing in front of a browser
/// route is a set of origin heuristics. If one is ever wrong, the
/// blast radius is "installs a plugin from a repo you already vetted,
/// at the commit you pinned" rather than "clones anything and puts it
/// on your disk". Trusting a *new* source stays `baguette bakery add`.
enum InstallDecision: Equatable {
    /// Serve it: this bakery is trusted and offers this plugin.
    case install(Bakery, plugin: String)
    /// The id isn't in `bakeries.json`. Nothing is cloned to find out.
    case notTrusted(bakery: String)
    /// Trusted source, but its recorded menu doesn't list this name —
    /// trusting a bakery is not trusting an arbitrary path inside it.
    case notOffered(plugin: String, by: Bakery)

    static func decide(bakery id: String, plugin: String, among trusted: [Bakery]) -> InstallDecision {
        guard let bakery = trusted.first(where: { $0.id == id }) else {
            return .notTrusted(bakery: id)
        }
        // An absent field arrives as "", and an empty name must never
        // fall through to "well, install the only one then".
        guard !plugin.isEmpty, bakery.plugins.contains(plugin) else {
            return .notOffered(plugin: plugin, by: bakery)
        }
        return .install(bakery, plugin: plugin)
    }

    /// Why this was refused, ready to show in the modal — or nil when
    /// it wasn't.
    ///
    /// A refusal never echoes an untrusted id back into the page. It
    /// names only things already the user's: the bakeries they trusted
    /// and the plugins those offer.
    var refusal: String? {
        switch self {
        case .install:
            return nil
        case .notTrusted:
            return """
                that bakery isn't trusted — add it in a terminal first with \
                `baguette bakery add owner/repo`, then reopen this
                """
        case .notOffered(_, let bakery):
            return """
                \(bakery.id) doesn't offer that plugin — it offers: \
                \(bakery.plugins.joined(separator: ", "))
                """
        }
    }
}
