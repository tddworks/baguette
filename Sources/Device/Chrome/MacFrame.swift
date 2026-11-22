import Foundation

/// A Mac's frame a Mac display can be shown in: a picture of a MacBook or an
/// iMac, its screen at the transparent opening measured in the picture. Its
/// pixels aren't baguette's to ship — they're read from a frames folder by
/// `name` — only where the screen sits is.
///
/// A frame fits a display only when its screen has the display's shape, so a
/// picture is never stretched and a click lands where it is pointed.
public struct MacFrame: Equatable, Sendable {
    /// How far a display's shape may stray from the frame's screen and still fit.
    public static let shapeTolerance = 0.02

    public let name: String
    /// The picture's size, in its pixels.
    public let image: Size
    /// The opening the screen shows through, in the picture's pixels.
    public let screen: Rect

    public init(name: String, image: Size, screen: Rect) {
        self.name = name
        self.image = image
        self.screen = screen
    }

    /// The frame as a bezel: the screen inset at its opening, square, no buttons.
    public var chrome: DeviceChrome {
        DeviceChrome(
            identifier: name,
            screenInsets: Insets(
                top: screen.origin.y,
                left: screen.origin.x,
                bottom: image.height - screen.origin.y - screen.size.height,
                right: image.width - screen.origin.x - screen.size.width),
            outerCornerRadius: 0,
            buttons: [],
            compositeImageName: nil)
    }

    /// Whether a display of `size` shows in this frame unstretched.
    public func fits(_ size: Size) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let display = size.width / size.height
        let opening = screen.size.width / screen.size.height
        return abs(display - opening) / opening <= Self.shapeTolerance
    }

    /// The frames a display of `size` fits, in the order measured.
    public static func fitting(_ size: Size) -> [MacFrame] {
        measured.filter { $0.fits(size) }
    }

    /// The frame named `name`, when one was measured.
    public static func named(_ name: String) -> MacFrame? {
        measured.first { $0.name == name }
    }

    /// Every frame measured: the screen is the picture's transparent opening,
    /// scanned clear of a MacBook's notch (design: docs/features/mac-screen/design.md).
    public static let measured: [MacFrame] = [
        frame("MacBook Air 13-inch (M4)", 3220, 2100, 330, 218, 2560, 1664),
        frame("MacBook Pro 14-inch", 3944, 2564, 461, 301, 3022, 1962),
        frame("MacBook Pro 14-inch (M4)", 3944, 2564, 461, 301, 3022, 1962),
        frame("MacBook Pro 15-inch (2017)", 3500, 2100, 460, 196, 2580, 1613),
        frame("MacBook Pro 16-inch (2019)", 3900, 2260, 467, 112, 2965, 1856),
        frame("MacBook Pro 16-inch", 4340, 2860, 443, 314, 3454, 2232),
        frame("MacBook Pro 16-inch (M4)", 4340, 2860, 443, 314, 3454, 2232),
        frame("iMac 24-inch", 4760, 4040, 140, 160, 4480, 2520),
        frame("iMac 27-inch", 5640, 4540, 260, 250, 5120, 2880),
    ]

    private static func frame(_ name: String, _ width: Double, _ height: Double,
                              _ x: Double, _ y: Double, _ screenWidth: Double, _ screenHeight: Double) -> MacFrame {
        MacFrame(name: name, image: Size(width: width, height: height),
                 screen: Rect(origin: Point(x: x, y: y), size: Size(width: screenWidth, height: screenHeight)))
    }
}
