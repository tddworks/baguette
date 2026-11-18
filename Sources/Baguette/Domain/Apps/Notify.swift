import Foundation
import Mockable

/// A device's notifications: a remote notification delivered to the app it
/// is addressed to, as if APNs had sent it. Its own act, not managing apps
/// — a device can install apps and not take notifications, or the reverse.
@Mockable
protocol Notify: Sendable {
    /// Success means the device accepted it — not that a banner showed
    /// (`RemoteNotification.expectation` says what to expect). Throws
    /// `AppsError.deliverFailed` with the device's own explanation when it
    /// refuses (app not installed, device not booted), and
    /// `AppsError.notificationsNotAllowed` when the app hasn't been allowed.
    func deliver(_ notification: RemoteNotification) async throws
}

extension Ability where Role == any Notify {
    static var notify: Self { .init(name: "notify") }
}
