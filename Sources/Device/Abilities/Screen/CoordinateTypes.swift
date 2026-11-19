import Foundation

/// A point in the simulator's screen-space, in points (top-left origin).
/// The infrastructure adapter clamps and normalizes to whatever the wire
/// requires; domain code stays in the user's units.
public struct Point: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Screen size in points. Carried with every gesture so the dispatch layer
/// can scale without knowing which device is target.
public struct Size: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Edge offsets in points (top/left/bottom/right). Used by `DeviceChrome`
/// for the bezel widths around the screen cutout.
public struct Insets: Equatable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// Origin + size, both in the same coordinate space. The chrome layout
/// returns one to describe where the screen sits inside a composite
/// image of a given pixel size.
public struct Rect: Equatable, Sendable {
    public let origin: Point
    public let size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }
}

/// Phase of a streaming touch gesture (`touch1` / `touch2`).
public enum GesturePhase: String, Sendable, Equatable, CaseIterable {
    case down, move, up
}

/// HID (page, usage) pair — the wire-level code SimulatorKit needs
/// to identify an arbitrary-HID button press. iPhone side buttons
/// live on consumer (page 12) and telephony (page 11) HID pages.
public struct HIDUsage: Equatable, Hashable, Sendable {
    public let page: UInt32
    public let usage: UInt32

    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }
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
    public static let allowed = allCases.map(\.rawValue).joined(separator: " | ")
}

