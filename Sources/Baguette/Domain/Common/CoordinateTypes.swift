import Foundation

/// A point in the simulator's screen-space, in points (top-left origin).
/// The infrastructure adapter clamps and normalizes to whatever the wire
/// requires; domain code stays in the user's units.
struct Point: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// Screen size in points. Carried with every gesture so the dispatch layer
/// can scale without knowing which device is target.
struct Size: Equatable, Sendable {
    let width: Double
    let height: Double
}

/// Edge offsets in points (top/left/bottom/right). Used by `DeviceChrome`
/// for the bezel widths around the screen cutout.
struct Insets: Equatable, Sendable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double
}

/// Origin + size, both in the same coordinate space. The chrome layout
/// returns one to describe where the screen sits inside a composite
/// image of a given pixel size.
struct Rect: Equatable, Sendable {
    let origin: Point
    let size: Size
}

/// Phase of a streaming touch gesture (`touch1` / `touch2`).
enum GesturePhase: String, Sendable, Equatable, CaseIterable {
    case down, move, up
}

/// Hardware buttons routable via the host-HID path on iOS 26.4. Other
/// buttons (Siri, Side, volume) crash backboardd through this path and
/// route through AXe instead.
enum DeviceButton: String, Sendable, Equatable {
    case home, lock
}
