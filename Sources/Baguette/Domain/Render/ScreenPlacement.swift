import BaguetteDevice
import Foundation

/// UV-space placement of a simulator frame on a device screen surface.
/// Scale below 1 crops the overflowing axis (cover); scale above 1
/// letterboxes the deficient axis (contain). Engine-agnostic: SceneKit
/// consumed this as a contents transform, RealityKit as a texture
/// coordinate transform.
struct ScreenPlacement: Equatable, Sendable {
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double

    static let identity = ScreenPlacement(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
}

/// An integer texture-space window, in source pixels.
struct ContentRegion: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

extension ScreenPlacement {
    /// The window of the source frame the screen surface can actually
    /// sample, inset by a feather border. Cover fits crop the source, so
    /// the window follows the crop rather than the texture bounds.
    func contentRegion(in source: RenderDimensions, inset: Int) -> ContentRegion {
        let lowU = max(0.0, offsetX)
        let highU = min(1.0, offsetX + scaleX)
        let lowV = max(0.0, offsetY)
        let highV = min(1.0, offsetY + scaleY)
        let x = Int((lowU * Double(source.width)).rounded()) + inset
        let y = Int((lowV * Double(source.height)).rounded()) + inset
        let maxX = Int((highU * Double(source.width)).rounded()) - inset
        let maxY = Int((highV * Double(source.height)).rounded()) - inset
        return ContentRegion(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }
}

extension DeviceScreenFit {
    func placement(source: RenderDimensions, target: RenderDimensions) -> ScreenPlacement {
        guard self != .stretch else { return .identity }
        let sourceAspect = Double(source.width) / Double(source.height)
        let targetAspect = Double(target.width) / Double(target.height)
        var scaleX = 1.0
        var scaleY = 1.0
        if (self == .cover) == (sourceAspect > targetAspect) {
            scaleX = targetAspect / sourceAspect
        } else {
            scaleY = sourceAspect / targetAspect
        }
        return ScreenPlacement(
            scaleX: scaleX,
            scaleY: scaleY,
            offsetX: (1 - scaleX) / 2,
            offsetY: (1 - scaleY) / 2
        )
    }
}
