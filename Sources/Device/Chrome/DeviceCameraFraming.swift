import Foundation

/// Perspective framing for a complete device model.
///
/// The lens stays fixed while zoom changes the camera's distance, matching a
/// physical camera and the native USDZ viewer instead of flattening depth.
public struct DeviceCameraFraming: Equatable, Sendable {
    public static let standardFieldOfViewDegrees = 32.0
    public static let standardPadding = 1.15

    public let fieldOfViewDegrees: Double
    public let distanceFromCenter: Double

    public static func fit(
        subjectWidth: Double,
        subjectHeight: Double,
        subjectDepth: Double,
        viewport: RenderDimensions
    ) -> DeviceCameraFraming {
        let width = max(subjectWidth, 0.1)
        let height = max(subjectHeight, 0.1)
        let depth = max(subjectDepth, 0.1)
        let aspect = Double(max(viewport.width, 1)) /
            Double(max(viewport.height, 1))
        let requiredHeight = max(height, width / aspect)
        let halfFieldOfView = standardFieldOfViewDegrees * .pi / 360
        let fittedDistance = (requiredHeight * standardPadding / 2) /
            tan(halfFieldOfView)

        return DeviceCameraFraming(
            fieldOfViewDegrees: standardFieldOfViewDegrees,
            distanceFromCenter: depth * 1.5 + fittedDistance
        )
    }

    public func distance(at zoom: Double) -> Double {
        distanceFromCenter / max(zoom, 0.01)
    }

    public init(fieldOfViewDegrees: Double, distanceFromCenter: Double) {
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.distanceFromCenter = distanceFromCenter
    }
}
