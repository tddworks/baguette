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

/// HID (page, usage) pair — the wire-level code SimulatorKit needs
/// to identify an arbitrary-HID button press. iPhone side buttons
/// live on consumer (page 12) and telephony (page 11) HID pages.
struct HIDUsage: Equatable, Hashable, Sendable {
    let page: UInt32
    let usage: UInt32
}

/// Screen-edge gesture region a streaming touch belongs to. When
/// set on a `touch1-*` envelope, the Infrastructure adapter
/// patches the `IndigoHIDEdge` byte slot in the message so iOS's
/// system gesture recognizers (home indicator, control centre,
/// notification centre) see the touch as an edge gesture rather
/// than an interior pan. Empirical bitmask values verified against
/// `IndigoHIDMessageForMouseNSEvent`'s 7-arg signature.
public enum DeviceEdge: String, Sendable, Equatable, Hashable, CaseIterable {
    case left, top, right, bottom

    /// The accepted spellings, for error messages and `--help`.
    static let allowed = allCases.map(\.rawValue).joined(separator: " | ")
}

