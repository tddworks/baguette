import Foundation
import Mockable

/// The apps installed on a device — "the apps on my phone." You add to
/// the collection by installing an `AppBundle`; uninstall / list aren't
/// modelled yet (drag-and-drop only ever *adds*). Named as the plural
/// collection noun per the aggregate convention, alongside `Simulators`
/// / `Chromes` / `Cameras`.
///
/// `@Mockable` so the serve route and CLI command can be unit-tested
/// without a booted simulator. The production impl is `SimctlApps`,
/// backed by `xcrun simctl install`.
@Mockable
public protocol Apps: Sendable {
    /// Install an app onto the device. Throws `AppsError.installFailed`
    /// when simctl exits non-zero (device not booted, bad bundle, …).
    func install(_ app: AppBundle) async throws

    /// Install an app that arrived zipped — a browser-packed or
    /// user-zipped folder-form `.app` (simctl can't take a zip
    /// directly). Extracts the archive, locates the single `.app`
    /// inside, and installs it through the normal `AppBundle` path.
    /// Throws `AppsError.extractFailed` when extraction dies,
    /// `.archiveTooLarge` when the extracted contents blow past the
    /// decompression cap (zip bomb), `.noAppInArchive` when nothing
    /// installable is inside, and `.installFailed` when simctl rejects
    /// the located app.
    func install(archive: AppArchive) async throws

    /// Open a deep link on the device — the app that registered the
    /// scheme comes to the foreground. Throws `AppsError.openFailed`
    /// when simctl exits non-zero.
    func open(_ link: DeepLink) async throws

    /// Every app on the device, each carrying the URL schemes it
    /// answers to. Throws `AppsError.listFailed` when simctl exits
    /// non-zero; an app whose bundle can't be read still lists, with no
    /// schemes, rather than dropping out of the roster.
    func installed() async throws -> [InstalledApp]

    /// Quit the app if it's running. An app that isn't running is
    /// already where the caller wants it, so that isn't an error. Throws
    /// `AppsError.terminateFailed` for any other simctl failure.
    func terminate(bundleID: String) async throws

    /// Launch the app. Throws `AppsError.launchFailed` when simctl exits
    /// non-zero (not installed, device not booted, …).
    func launch(bundleID: String) async throws
}

/// Failure modes surfaced when installing an app. Maps to a CLI exit
/// message and an HTTP status on the serve route (bad archives are the
/// client's fault → 4xx; simctl failures are the device's → 5xx).
public enum AppsError: Error, Equatable, CustomStringConvertible {
    case installFailed(status: Int32)
    case extractFailed(status: Int32)
    case archiveTooLarge(bytes: Int64, limit: Int64)
    case noAppInArchive
    case openFailed(status: Int32)
    case deliverFailed(status: Int32, message: String)
    /// The simulator refused a notification because the app isn't a
    /// notification source it will accept: it never asked for (or wasn't
    /// granted) permission — or isn't installed, which reads the same.
    case notificationsNotAllowed(app: String)
    case listFailed(status: Int32)
    case terminateFailed(status: Int32)
    case launchFailed(status: Int32)

    public var description: String {
        switch self {
        case .installFailed(let status):
            return "xcrun simctl install exited \(status)"
        case .openFailed(let status):
            return "xcrun simctl openurl exited \(status)"
        case .notificationsNotAllowed(let app):
            return "\(app) isn't allowed to receive notifications: it must ask with "
                + "UNUserNotificationCenter.requestAuthorization and be allowed (or it isn't installed)"
        case .deliverFailed(let status, let message):
            return message.isEmpty
                ? "xcrun simctl push exited \(status)"
                : "xcrun simctl push exited \(status): \(message)"
        case .listFailed(let status):
            return "xcrun simctl listapps exited \(status)"
        case .terminateFailed(let status):
            return "xcrun simctl terminate exited \(status)"
        case .launchFailed(let status):
            return "xcrun simctl launch exited \(status)"
        case .extractFailed(let status):
            return "ditto -x -k exited \(status) (corrupt zip?)"
        case .archiveTooLarge(let bytes, let limit):
            return "archive inflates to \(bytes) bytes, over the \(limit)-byte cap (zip bomb?)"
        case .noAppInArchive:
            return "no single .app bundle at the top level of the zip"
        }
    }
}
