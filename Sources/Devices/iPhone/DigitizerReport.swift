import BaguetteDevice
import Foundation

/// One Universal HID digitizer report, as values: the fingers on the glass
/// now, or lifting, each numbered from one. UniversalHID's own setters lay
/// it out (`UniversalHIDReport`), field by field from this.
struct DigitizerReport: Equatable, Sendable {
    /// The way a swipe in from an edge moves: inward, away from it.
    enum Swipe: Equatable, Sendable {
        case right, down, up, left

        /// In from the left moves right; from the top, down; and so on.
        init(inFrom edge: DeviceEdge) {
            switch edge {
            case .left: self = .right
            case .top: self = .down
            case .bottom: self = .up
            case .right: self = .left
            }
        }
    }

    struct Finger: Equatable, Sendable {
        /// Its contact's index and identity, from one.
        let index: Int
        let x: Double
        let y: Double
        /// Touching, and in range; a lifting finger is neither.
        let touching: Bool
        /// A swipe in from an edge, marked on every report including the
        /// lift (with "locked"), so SpringBoard finishes it.
        let swipe: Swipe?
    }

    let fingers: [Finger]

    init(contacts: [Contact], touching: Bool, edge: DeviceEdge?) {
        let swipe = edge.map(Swipe.init(inFrom:))
        fingers = contacts.enumerated().map { index, contact in
            Finger(index: index + 1, x: contact.x, y: contact.y, touching: touching, swipe: swipe)
        }
    }
}
