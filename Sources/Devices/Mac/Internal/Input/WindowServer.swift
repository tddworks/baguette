import Foundation
import Mockable

/// The Mac's window server, one event at a time: whether this process is
/// trusted for Accessibility (`asking` shows the system's prompt), and an
/// event posted. Decides nothing; the real one is `CGEventWindowServer`.
@Mockable
protocol WindowServer: Sendable {
    func trusted(asking: Bool) -> Bool
    /// Any event but a pause.
    func post(_ event: HostEvent)
}
