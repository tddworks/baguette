import BaguetteDevice
import Foundation

/// The side of the desktop the Dock lives on, as macOS stores it
/// (`com.apple.dock orientation`); the bottom when it says nothing.
public enum DockEdge: Equatable, Sendable {
    case left, bottom, right

    public init(orientation: String?) {
        switch orientation {
        case "left": self = .left
        case "right": self = .right
        default: self = .bottom
        }
    }
}

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

    /// Every display's origin once `display` is main, and — `freeing` a Dock
    /// edge — moved first to the end of the desktop on the Dock's side, top
    /// aligned, so no display is beside its Dock edge: an auto-hidden Dock comes
    /// up only when the pointer meets the desktop's edge there, and a display
    /// beside it takes the pointer instead (measured: a share made main with the
    /// UP2516D to its right never showed a right-hand Dock). A Dock at the
    /// bottom is freed at the right end too: nothing is below it there. The
    /// other displays keep their places among themselves. Nil when `display`
    /// isn't one of them.
    static func makingMain(_ display: UInt32, in bounds: [UInt32: Rect], freeing edge: DockEdge?) -> [UInt32: Point]? {
        guard let target = bounds[display] else { return nil }
        var origins = bounds.mapValues(\.origin)
        let others = bounds.filter { $0.key != display }.values
        if let edge, !others.isEmpty {
            let top = others.map(\.origin.y).min() ?? 0
            switch edge {
            case .right, .bottom:
                origins[display] = Point(x: others.map { $0.origin.x + $0.size.width }.max() ?? 0, y: top)
            case .left:
                origins[display] = Point(x: (others.map(\.origin.x).min() ?? 0) - target.size.width, y: top)
            }
        }
        return makingMain(display, in: origins)
    }
}
