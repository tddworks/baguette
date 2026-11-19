import Foundation

/// How a foldable's model is posed for a hinge angle.
///
/// The model's shutting clip raises the left half alone, from flat at
/// its start to shut at the fold's shut time. Device Hub's open poses are
/// a centred bend, so the whole device turns back by half the fold to
/// share it between the halves — fully above the open pose, handing
/// over as the book shuts so the cover ends facing the camera.
public struct FoldPose: Equatable, Sendable {
    public let clipTime: Double
    /// About the hinge axis, degrees; negative turns the raised left half
    /// back toward the camera's centre line.
    public let yawDegrees: Double

    public static func at(degrees: Double, fold: DeviceModelFold) -> FoldPose {
        let angle = max(0, min(180, degrees))
        let foldDegrees = 180 - angle
        let share = max(0, min(1, angle / fold.openPoseDegrees))
        return FoldPose(
            clipTime: foldDegrees / 180 * fold.shutTime,
            yawDegrees: -(foldDegrees / 2) * share
        )
    }

    /// The shift that keeps the book in the middle as it folds, as
    /// Device Hub keeps the device centred in its window: the bent
    /// screen's extent — the left half raised by the clip and the whole
    /// turned back — brought back so its middle sits at the origin.
    /// `inner` is the unfolded screen in the rest frame, the hinge the y
    /// axis through x = 0. Only the sideways shift matters; depth and
    /// height stay the model's.
    public static func centring(inner: ScreenLocalCorners, hingeDegrees: Double, fold: DeviceModelFold) -> Vector3 {
        let pose = at(degrees: hingeDegrees, fold: fold)
        let raise = 180 - max(0, min(180, hingeDegrees))
        let seamTop = Vector3(x: 0, y: inner.topLeft.y, z: inner.topLeft.z)
        let seamBottom = Vector3(x: 0, y: inner.bottomLeft.y, z: inner.bottomLeft.z)
        let left = [inner.topLeft, inner.bottomLeft].map { ScreenQuadProjection.rotateY($0, degrees: raise) }
        let points = (left + [seamTop, seamBottom, inner.topRight, inner.bottomRight])
            .map { ScreenQuadProjection.rotateY($0, degrees: pose.yawDegrees) }
        let xs = points.map(\.x)
        let middle = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        return Vector3(x: -middle, y: 0, z: 0)
    }

    public init(clipTime: Double, yawDegrees: Double) {
        self.clipTime = clipTime
        self.yawDegrees = yawDegrees
    }
}

/// How far a foldable's model turns about the camera axis so that it
/// stands the way the guest is held. The lit panel has an orientation
/// of its own — the unfolded panel is landscape-left lying flat in the
/// model, the cover portrait — and each step of the interface cycle
/// (portrait → landscape-left → upside-down → landscape-right) is the
/// device turned another quarter turn.
public enum InterfaceRoll {
    private static let cycle: [DeviceOrientation] = [
        .portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight,
    ]

    public static func degrees(_ orientation: DeviceOrientation, litPanel: IntegratedPanel) -> Double {
        let natural: DeviceOrientation = litPanel == .primary ? .portrait : .landscapeLeft
        let steps = ((cycle.firstIndex(of: orientation)! - cycle.firstIndex(of: natural)!) % 4 + 4) % 4
        // Measured against Device Hub: one step of the cycle is the
        // body turned a quarter turn clockwise on screen, which is a
        // negative roll about the camera axis.
        switch steps {
        case 1: return -90
        case 2: return 180
        case 3: return 90
        default: return 0
        }
    }
}
