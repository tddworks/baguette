import CoreGraphics
import Foundation

/// Converts UIKit screen points to the panel's native HID point space.
/// The bridge delegate leaves guest frames unchanged; application bounds
/// are neither host-window bounds nor a source of screen scale.
struct AXFrameTransform: Equatable, Sendable {
    let pointSize: CGSize
    let orientation: DeviceOrientation

    func map(_ frame: CGRect) -> CGRect {
        switch orientation {
        case .portrait:
            return frame
        case .portraitUpsideDown:
            return CGRect(
                x: pointSize.width - frame.maxX, y: pointSize.height - frame.maxY,
                width: frame.width, height: frame.height
            )
        case .landscapeLeft:
            return CGRect(
                x: frame.minY, y: pointSize.height - frame.maxX,
                width: frame.height, height: frame.width
            )
        case .landscapeRight:
            return CGRect(
                x: pointSize.width - frame.maxY, y: frame.minX,
                width: frame.height, height: frame.width
            )
        }
    }

    /// The strip along the top of the interface, where the status bar
    /// lives, in native panel points. UIKit's width is the panel's height
    /// once the interface is rotated sideways.
    func topStrip(height: CGFloat) -> CGRect {
        let sideways = orientation == .landscapeLeft || orientation == .landscapeRight
        let width = sideways ? pointSize.height : pointSize.width
        return map(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// AXP hit testing accepts UIKit screen points, so invert the same
    /// rotation used for every element returned from that request.
    func unmap(_ point: CGPoint) -> CGPoint {
        switch orientation {
        case .portrait:
            return point
        case .portraitUpsideDown:
            return CGPoint(x: pointSize.width - point.x, y: pointSize.height - point.y)
        case .landscapeLeft:
            return CGPoint(x: pointSize.height - point.y, y: point.x)
        case .landscapeRight:
            return CGPoint(x: point.y, y: pointSize.width - point.x)
        }
    }
}
