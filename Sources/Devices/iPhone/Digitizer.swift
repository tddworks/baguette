import BaguetteDevice
import Foundation
import Mockable

/// One finger on the glass, as a fraction of the screen each way (0…1),
/// in the panel's native orientation — what a touch controller reports.
struct Contact: Equatable, Sendable {
    let x: Double
    let y: Double
}

extension Point {
    /// This point as a finger on a screen of `size` device points, kept on
    /// the screen when it is given outside it.
    func contact(on size: Size) -> Contact {
        Contact(
            x: min(1, max(0, x / size.width)),
            y: min(1, max(0, y / size.height)))
    }
}

/// A touch controller baguette can feed directly — a physical phone's,
/// reached through CoreDevice. Each report is the fingers on the glass now,
/// or the same fingers lifting. `edge` marks a swipe in from that edge, so
/// the system reads Home and Control Center gestures.
@Mockable
protocol Digitizer: Sendable {
    func report(_ contacts: [Contact], touching: Bool, edge: DeviceEdge?) -> Bool
}
