import Foundation

/// An installable app file on the host — the thing the user means when
/// they drag an `.ipa` onto a device and think "install this app." The
/// value is the unit-testable heart of the install path: `at(_:)`
/// answers "is this file an app?" purely by extension (no disk access,
/// so the serve route can reject before reading the upload body), and
/// `installArguments` projects the argv tail for
/// `xcrun simctl install <udid> <path>`. The Infrastructure adapter
/// (`SimctlApps`) just prepends `xcrun` and runs it.
public struct AppBundle: Equatable, Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// File extensions `xcrun simctl install` accepts. `.app` is a
    /// directory bundle, `.ipa` a zip — both install the same way.
    public static let installableExtensions: Set<String> = ["ipa", "app"]

    /// Classify a host file as an installable app, or `nil` when its
    /// extension isn't one simctl can install. Matches on extension
    /// only — case-insensitively — so the decision is pure and works
    /// before the bytes ever land on disk.
    public static func at(_ path: URL) -> AppBundle? {
        guard installableExtensions.contains(path.pathExtension.lowercased()) else { return nil }
        return AppBundle(path: path)
    }

    /// The argv tail handed to `xcrun simctl [--set <set>] install <udid> <path>`.
    public func installArguments(udid: String, deviceSetPath: String? = nil) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["install", udid, path.path]
    }
}
