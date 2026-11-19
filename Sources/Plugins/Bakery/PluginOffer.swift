import BaguetteDevice
import Foundation

/// One plugin a trusted bakery offers, and whether this machine
/// already has it.
///
/// The browser's plugin shelf renders exactly this. The join is done
/// here rather than in JavaScript for the usual reason — the page is a
/// dumb renderer — and for one specific one: "installed" is not the
/// same question as "in `installed.json`". A bundled plugin like
/// `a11y` ships inside the binary and has no provenance record, so the
/// caller passes the names of everything the plugin scan can actually
/// see and a bakery offering `a11y` correctly reads as satisfied.
struct PluginOffer: Equatable, Sendable {
    let name: String
    let installed: Bool

    /// What `bakery` is offering, against the plugins already present.
    ///
    /// Menu order is preserved: it's the bakery author's ordering, and
    /// a bakery that put its headline plugin first meant to.
    static func list(of bakery: Bakery, installed: Set<String>) -> [PluginOffer] {
        bakery.plugins.map { PluginOffer(name: $0, installed: installed.contains($0)) }
    }
}
