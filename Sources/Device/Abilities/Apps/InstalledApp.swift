import Foundation

/// An app present on a device, and the URL schemes it answers to — the
/// inventory behind console completion. Typing `myap` can only suggest
/// `myapp://` once something has read the device's schemes.
///
/// Assembling one takes two reads, because neither source has the whole
/// picture:
///
/// 1. `xcrun simctl listapps <udid>` gives the authoritative roster —
///    which apps are installed, what they're called, and crucially each
///    one's real `Path` on disk. What it does *not* give is
///    `CFBundleURLTypes`: the command reports a curated subset of
///    metadata, and URL types aren't in it (verified against Xcode 26).
/// 2. `<Path>/Info.plist` gives the schemes, from the same key the app
///    declared them under.
///
/// Taking the path from step one is what makes step two safe. Reading
/// `Info.plist` means touching CoreSimulator's container layout, whose
/// `…/Containers/Bundle/Application/<uuid>/` shape is undocumented and
/// whose UUID changes on every reinstall — but we never have to *guess*
/// it, because simctl just told us. Both parses are pure and live here;
/// `SimctlApps` runs the child, reads the file, and composes them.
public struct InstalledApp: Equatable, Sendable {
    public let bundleIdentifier: String

    /// Display name, for showing next to a suggested scheme. Falls back
    /// through `CFBundleName` to the bundle identifier so this is never
    /// empty.
    public let name: String

    /// The app bundle on disk, as reported by `listapps`. `nil` when
    /// simctl reports an app without a path — nothing to read schemes
    /// from, so it simply contributes no completions.
    public let bundlePath: URL?

    /// Registered schemes, lower-cased and de-duplicated, in declaration
    /// order. Apps routinely register several — a readable one, a
    /// reverse-DNS one, and often a tool-injected dev-client one — so
    /// this is a list, and ranking is the caller's problem.
    public let schemes: [String]

    public init(
        bundleIdentifier: String,
        name: String,
        bundlePath: URL? = nil,
        schemes: [String] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        // Normalised here rather than only where plists are parsed,
        // because the invariant is load-bearing: `SchemeSuggestion`
        // lower-cases the needle and compares it against the stored
        // scheme, so an upper-cased one matches nothing at all. Anything
        // that documents an invariant and leaves its initialiser free to
        // break it is documenting a hope.
        self.schemes = Self.normalised(schemes)
    }

    /// Lower-cased, de-duplicated, in declaration order.
    public static func normalised(_ schemes: [String]) -> [String] {
        var seen: Set<String> = []
        return schemes.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    /// The same app, with schemes read from its bundle attached.
    public func withSchemes(_ schemes: [String]) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: name,
            bundlePath: bundlePath,
            schemes: schemes
        )
    }

    /// Step one: read `simctl listapps` output into a roster, ordered by
    /// bundle identifier so the console's suggestion list is stable
    /// between invocations. Every app comes back with no schemes — they
    /// aren't in this output. Unreadable output yields no apps rather
    /// than throwing: a device with nothing installed and a device that
    /// answered with garbage are the same to the caller, no completions.
    public static func all(fromListApps data: Data) -> [InstalledApp] {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let root = plist as? [String: Any]
        else { return [] }

        return root.keys.sorted().compactMap { identifier in
            guard let entry = root[identifier] as? [String: Any] else { return nil }
            return InstalledApp(
                bundleIdentifier: identifier,
                name: entry["CFBundleDisplayName"] as? String
                    ?? entry["CFBundleName"] as? String
                    ?? identifier,
                bundlePath: (entry["Path"] as? String).map { URL(fileURLWithPath: $0) }
            )
        }
    }

    /// Step two: the schemes an app declares, read from its
    /// `Info.plist`. An app declares one entry per URL type and each
    /// entry carries its own scheme list, so an app's schemes are the
    /// union across entries.
    public static func schemes(inInfoPlist data: Data) -> [String] {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let root = plist as? [String: Any],
              let types = root["CFBundleURLTypes"] as? [[String: Any]]
        else { return [] }

        return normalised(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
    }
}
