import Foundation
import CoreGraphics

/// Projects a `CGRect` reported by `AXPTranslator` (in macOS
/// host-window coordinates — where the simulator's window would
/// land on the host's screen) into device-point coordinates,
/// matching the units the gesture wire uses (`tap.x`, `tap.y`,
/// `width`, `height`).
///
/// The math is width-uniform scale + vertical centering offset,
/// which is exactly what Simulator.app does when a tall device
/// has to letterbox into a short window. Falls back to identity
/// when either the AX root frame or the device point-size has a
/// zero dimension — that's how we avoid dividing by zero on a
/// just-booted simulator that hasn't reported its bounds yet.
struct AXFrameTransform: Equatable, Sendable {
    let rootFrame: CGRect
    let pointSize: CGSize

    func map(_ macFrame: CGRect) -> CGRect {
        guard rootFrame.width > 0,
              rootFrame.height > 0,
              pointSize.width > 0,
              pointSize.height > 0
        else { return macFrame }

        let scale = pointSize.width / rootFrame.width
        let yOffset = (pointSize.height - rootFrame.height * scale) / 2
        return CGRect(
            x: (macFrame.origin.x - rootFrame.origin.x) * scale,
            y: (macFrame.origin.y - rootFrame.origin.y) * scale + yOffset,
            width: macFrame.size.width * scale,
            height: macFrame.size.height * scale
        )
    }

    /// Inverse of `map(_:)`: takes a device-point coordinate (the
    /// units callers pass into the gesture wire) and projects it
    /// back to macOS host-window coordinates. Needed when feeding
    /// AXP APIs that work in host coordinates — most notably
    /// `objectAtPoint:displayId:bridgeDelegateToken:`, where the
    /// translator interprets the point in its own host coordinate
    /// space, not in device points. Falls back to identity under
    /// the same zero-dimension conditions as `map(_:)`.
    func unmap(_ devicePoint: CGPoint) -> CGPoint {
        guard rootFrame.width > 0,
              rootFrame.height > 0,
              pointSize.width > 0,
              pointSize.height > 0
        else { return devicePoint }

        let scale = pointSize.width / rootFrame.width
        let yOffset = (pointSize.height - rootFrame.height * scale) / 2
        return CGPoint(
            x: devicePoint.x / scale + rootFrame.origin.x,
            y: (devicePoint.y - yOffset) / scale + rootFrame.origin.y
        )
    }
}
