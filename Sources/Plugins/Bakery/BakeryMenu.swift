import BaguetteDevice
import Foundation

/// A bakery's `baguette.json` — its *menu*: which plugins it offers and
/// where each one lives in the repo. Distinct from a plugin's own
/// `baguette-plugin.json` manifest; a bakery has a menu, a plugin has a
/// manifest.
///
/// Requiring this file (rather than guessing a layout) is deliberate: a
/// repo can be anything, and the menu is the one explicit statement of
/// "these paths are plugins." Parsing is pure and validates every path
/// stays inside the repo, because those paths are copied out onto the
/// user's disk on install.
struct BakeryMenu: Equatable, Sendable {
    let name: String?
    let description: String?
    let entries: [Entry]

    struct Entry: Equatable, Sendable {
        /// What the user types to install; also how the bakery refers
        /// to the plugin. The installed plugin's own identity still
        /// comes from its `baguette-plugin.json`.
        let name: String
        /// Repo-relative directory containing the plugin.
        let path: String
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    // MARK: - parsing

    static func parsing(json data: Data) throws -> BakeryMenu {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BakeryMenuError.malformedJSON
        }
        guard let dict = raw as? [String: Any] else {
            throw BakeryMenuError.malformedJSON
        }

        guard let pluginDicts = dict["plugins"] as? [[String: Any]], !pluginDicts.isEmpty else {
            throw BakeryMenuError.noPlugins
        }

        let entries = try pluginDicts.enumerated().map { index, entry -> Entry in
            guard let name = entry["name"] as? String, !name.isEmpty else {
                throw BakeryMenuError.entryMissingField(index: index, field: "name")
            }
            guard let path = entry["path"] as? String, !path.isEmpty else {
                throw BakeryMenuError.entryMissingField(index: index, field: "path")
            }
            guard Self.isRepoRelative(path) else {
                throw BakeryMenuError.unsafePath(index: index, path: path)
            }
            return Entry(name: name, path: path)
        }

        return BakeryMenu(
            name: dict["name"] as? String,
            description: dict["description"] as? String,
            entries: entries
        )
    }

    /// A path is safe to join onto the clone dir only if it stays
    /// inside it: not absolute, and no `..` component. Mirrors the
    /// spirit of `WebRoot.safeRelativeAssetPath`.
    private static func isRepoRelative(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.allSatisfy { $0 != ".." }
    }
}

enum BakeryMenuError: Error, Equatable, CustomStringConvertible {
    case missing
    case malformedJSON
    case noPlugins
    case entryMissingField(index: Int, field: String)
    case unsafePath(index: Int, path: String)

    var description: String {
        switch self {
        case .missing:
            return "no baguette.json at the repo root — this isn't a bakery"
        case .malformedJSON:
            return "baguette.json is not a JSON object"
        case .noPlugins:
            return "baguette.json lists no \"plugins\" — this repo isn't a bakery"
        case .entryMissingField(let index, let field):
            return "plugins[\(index)] is missing \"\(field)\""
        case .unsafePath(let index, let path):
            return "plugins[\(index)] path \"\(path)\" escapes the repo — must be a relative path with no .."
        }
    }
}
