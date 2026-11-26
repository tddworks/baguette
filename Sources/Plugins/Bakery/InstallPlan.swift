import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// The pure brain of installation: given a reference, an optional
/// explicitly-requested plugin name, and the bakery's menu, decide
/// which menu entries to install — or refuse with a typed reason.
///
/// No I/O lives here. The App orchestrator (`BakeryInstall`) clones the
/// repo and copies the resolved directories; this type only decides
/// *what*, so the decision is exhaustively unit-tested.
enum InstallPlan {

    /// Resolution precedence: an explicitly `requested` name, else the
    /// `ref`'s plugin segment, else the sole entry if the bakery has
    /// exactly one. A bare reference against a multi-plugin bakery is
    /// ambiguous rather than "install everything" — the user should
    /// say which.
    static func resolve(
        ref: BakeryRef, requested: String?, menu: BakeryMenu
    ) throws -> [BakeryMenu.Entry] {
        let available = menu.entries.map(\.name)

        if let name = requested ?? ref.plugin {
            guard let entry = menu.entry(named: name) else {
                throw InstallPlanError.notOffered(name: name, available: available)
            }
            return [entry]
        }

        if menu.entries.count == 1 {
            return menu.entries
        }
        throw InstallPlanError.ambiguous(available: available)
    }
}

enum InstallPlanError: Error, Equatable, CustomStringConvertible {
    case ambiguous(available: [String])
    case notOffered(name: String, available: [String])

    var description: String {
        switch self {
        case .ambiguous(let available):
            return """
                this bakery offers more than one plugin — name which: \
                \(available.joined(separator: ", "))
                """
        case .notOffered(let name, let available):
            return """
                no plugin \"\(name)\" in this bakery — it offers: \
                \(available.joined(separator: ", "))
                """
        }
    }
}
