import Foundation

/// The part of a decoded picture that is the screen, in the terms a
/// decoder crops by: a size, and how far its centre sits from the
/// picture's centre (negative is up and left). A phone's stream pads its
/// screen on the right and bottom — 1320 × 2868 arrives as 1328 × 2896 —
/// so the screen is the picture's top-left.
public struct CleanAperture: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let horizontalOffset: Double
    public let verticalOffset: Double

    public init(width: Double, height: Double, horizontalOffset: Double, verticalOffset: Double) {
        self.width = width
        self.height = height
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
    }

    /// Nil when there is nothing to crop: the picture is no larger than the
    /// screen (or is turned the other way, which the screen size can't say).
    public init?(screen: Size, picture: Size) {
        guard screen.width <= picture.width, screen.height <= picture.height,
              screen.width < picture.width || screen.height < picture.height
        else { return nil }
        self.init(width: screen.width, height: screen.height,
                  horizontalOffset: (screen.width - picture.width) / 2,
                  verticalOffset: (screen.height - picture.height) / 2)
    }
}
