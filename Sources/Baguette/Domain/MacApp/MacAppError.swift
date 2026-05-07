import Foundation

/// Failure modes the `MacApps` aggregate (and its capability ports)
/// surface. Each maps to a CLI exit message.
///
/// `tccDenied` is the load-bearing case on macOS — Screen Recording,
/// Accessibility, and Input Monitoring all require explicit user grants
/// that may be missing on first run. The `scope` field tells the user
/// which pane in System Settings → Privacy & Security to open.
enum MacAppError: Error, Equatable {
    case notFound(bundleID: String)
    case tccDenied(scope: TCCScope)
    case launchFailed

    /// Which TCC scope the user needs to grant. The CLI maps this to a
    /// human-readable hint pointing at the right Privacy & Security pane.
    enum TCCScope: String, Sendable, Equatable {
        /// Screen Recording — `SCShareableContent`, screenshots.
        case screen
        /// Accessibility — `AXUIElement` reads of other apps.
        case accessibility
        /// Input Monitoring (granted with Accessibility on macOS 26) —
        /// `CGEventPost` to other apps.
        case input
    }
}
