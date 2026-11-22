import BaguetteDevice
import Foundation

/// Where this Mac's displays sit on its desktop, by `CGDirectDisplayID`. The
/// main display — the menu bar, the Dock, new windows — is the one at the
/// origin, so making another main shifts them all by its origin, each keeping
/// its place beside the others.
enum DisplayOrigins {
    /// Every display's origin once `display` is main; nil when it isn't one of them.
    static func makingMain(_ display: UInt32, in origins: [UInt32: Point]) -> [UInt32: Point]? {
        guard let target = origins[display] else { return nil }
        return origins.mapValues { Point(x: $0.x - target.x, y: $0.y - target.y) }
    }
}
