import BaguetteDevice
import Foundation

/// The screen of the device a viewer shares this Mac to: its size in its own
/// points and how many pixels make one, as its browser reports them.
public struct ViewerScreen: Equatable, Sendable {
    public let points: Size
    let pixelsPerPoint: Double
}

/// The display this Mac is shared through: the viewer's shape exactly, with
/// as much room for the Mac as the viewer asks for, drawn at twice its points
/// (HiDPI) — never more pixels than the hardware H.264 encoder takes on its
/// long side.
public struct SharedScreenShape: Equatable, Sendable {
    /// How much room the Mac gets on the viewer's screen.
    public enum Room: Double, Sendable, CaseIterable {
        /// The Mac's points are the viewer's: text the size of the viewer's own.
        case largerText = 1
        /// One and a half: on a 3× phone, the display's pixels are the phone's own.
        case standard = 1.5
        /// Twice the viewer's points: the most room, the smallest text.
        case moreSpace = 2

        /// The room a viewer asks for by name; standard when they name none,
        /// nil for a name that isn't one.
        public init?(wire: String?) {
            switch wire {
            case nil: self = .standard
            case "largerText": self = .largerText
            case "standard": self = .standard
            case "moreSpace": self = .moreSpace
            default: return nil
            }
        }
    }

    /// The display's size in its points.
    public let points: Size

    /// What it draws in: two pixels a point.
    var pixels: Size { Size(width: points.width * 2, height: points.height * 2) }

    /// Whether a mode the display offers is its own: its points, two pixels to
    /// each. macOS offers it beside a 1× mode of the same pixels, and starts
    /// on the 1× one, so it is chosen by name.
    func isMode(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
        Double(width) == points.width && Double(height) == points.height
            && Double(pixelWidth) == pixels.width && Double(pixelHeight) == pixels.height
    }

    /// A shape already worked out — as a `virtual-display` process is handed it.
    public init(points: Size) {
        self.points = points
    }

    public init(viewer: ViewerScreen, room: Room) {
        let width = viewer.points.width * room.rawValue
        let height = viewer.points.height * room.rawValue
        let fit = min(1, DisplayCaptureSize.longestSide / (2 * max(width, height)))
        points = Size(width: (width * fit).rounded(.down), height: (height * fit).rounded(.down))
    }
}
