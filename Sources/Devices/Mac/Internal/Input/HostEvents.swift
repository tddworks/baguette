import Foundation
import Mockable

/// The Mac's window server, as something told events: each posted in order,
/// pauses kept. False when it can't be told — this process isn't trusted for
/// Accessibility, so the window server would drop them. Decides nothing; the
/// real one is `WindowServerEvents`.
@Mockable
protocol HostEvents: Sendable {
    func post(_ events: [HostEvent]) -> Bool
}
