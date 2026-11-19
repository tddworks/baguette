import Foundation

/// A set of an app's preferences: its standard defaults
/// (`UserDefaults.standard`), or a named suite — one of its App Groups
/// (`UserDefaults(suiteName: "group.…")`) or a suite of its own.
///
/// It never guesses a container path. CoreSimulator's
/// `…/Containers/Data/Application/<uuid>/` layout is undocumented and the
/// UUID changes on every reinstall, so `containerArguments` asks simctl
/// for it; only the plist *inside* the reported container is ours to
/// name. For an App Group, simctl lists the groups the app's own entitlements
/// grant, so a group the app doesn't belong to fails loudly instead of
/// quietly landing in standard defaults.
public struct PreferenceSuite: Equatable, Sendable {
    public let bundleID: String
    /// The `suiteName`, or `nil` for the app's standard defaults. A name
    /// starting `group.` is an App Group (Apple requires the prefix) and
    /// lives in that group's container; any other name
    /// (`UserDefaults(suiteName: "com.example.debug")`) is the app's own
    /// and lives in its data container. Either way the plist is named for
    /// it.
    public let name: String?

    /// The App Group this suite lives in, or `nil` when the preferences
    /// are in the app's own data container.
    public var group: String? {
        name.flatMap { $0.hasPrefix("group.") ? $0 : nil }
    }

    /// Both identifiers become a path component and a simctl argument, so
    /// anything that could climb out of the container (`/`, `..`) or read
    /// as a flag (`-…`) is refused here, before it reaches either.
    public init(bundleID: String, name: String? = nil) throws {
        guard Self.isIdentifier(bundleID) else {
            throw PreferenceSuiteError.invalidIdentifier(bundleID)
        }
        if let name, !Self.isIdentifier(name) {
            throw PreferenceSuiteError.invalidIdentifier(name)
        }
        self.bundleID = bundleID
        self.name = name
    }

    /// `xcrun` argv that prints where these preferences live: the app's
    /// data container, or — for an App Group suite — every App Group
    /// container the app has, as `<group id>\t<path>` lines. simctl's own
    /// `<group id>` form exits 117 even for a group the app has (Xcode
    /// 27), so the group is picked out of the listing instead.
    public func containerArguments(udid: String, deviceSetPath: String? = nil) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["get_app_container", udid, bundleID, group == nil ? "data" : "groups"]
    }

    /// The preferences plist inside the container simctl printed, or
    /// `nil` when it names none — for an App Group suite, when the app's
    /// groups don't include it.
    public func plistPath(inContainerOutput output: String) -> String? {
        let container: String?
        if let group {
            container = Self.groupContainers(inListing: output).first { $0.group == group }?.path
        } else {
            container = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let container, !container.isEmpty else { return nil }
        return container + "/Library/Preferences/\(name ?? bundleID).plist"
    }

    /// The App Groups an app has, sorted, from `get_app_container …
    /// groups` output — what a suite picker offers.
    public static func groups(inListing output: String) -> [String] {
        groupContainers(inListing: output).map(\.group).sorted()
    }

    /// `<group id>\t<path>` lines, as `get_app_container … groups` prints them.
    private static func groupContainers(inListing output: String) -> [(group: String, path: String)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && !text.contains("/") && !text.contains("..")
    }
}

public enum PreferenceSuiteError: Error, Equatable, CustomStringConvertible {
    case invalidIdentifier(String)

    public var description: String {
        switch self {
        case .invalidIdentifier(let text):
            return "\"\(text)\" is not a bundle or App Group identifier"
        }
    }
}
