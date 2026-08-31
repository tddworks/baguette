import Foundation

/// A physical phone's orientation — a unit quaternion in CoreMotion's
/// `[x, y, z, w]` component order, which is also the wire order the
/// companion sends. Owns the math that must be exact for the twin:
/// re-zero calibration and shortest-path smoothing. `q` and `-q`
/// encode the same attitude, so equality-as-attitude and slerp both
/// treat the pair as one pose.
struct Attitude: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double

    static let identity = Attitude(x: 0, y: 0, z: 0, w: 1)

    init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// Parse the wire payload — exactly four numbers, CoreMotion order.
    init?(wire: [Double]) {
        guard wire.count == 4 else { return nil }
        self.init(x: wire[0], y: wire[1], z: wire[2], w: wire[3])
    }

    /// The same attitude with every component negated — a sign flip a
    /// sender may legally produce between samples.
    var negated: Attitude {
        Attitude(x: -x, y: -y, z: -z, w: -w)
    }

    /// For unit quaternions the inverse is the conjugate.
    var inverse: Attitude {
        Attitude(x: -x, y: -y, z: -z, w: w)
    }

    /// Hamilton product — compose two rotations.
    static func * (lhs: Attitude, rhs: Attitude) -> Attitude {
        Attitude(
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
        )
    }

    /// Rotation relative to a captured reference pose. Re-zero stores
    /// the pose the phone held when the user pressed the button; from
    /// then on that pose is the identity and the model faces front.
    func rezeroed(against reference: Attitude) -> Attitude {
        reference.inverse * self
    }

    /// Spherical interpolation toward `target`, always along the
    /// shortest path: when the target's sign is flipped relative to
    /// self (negative dot product), the target is negated first so the
    /// pose never swings the long way round.
    func slerped(toward target: Attitude, fraction: Double) -> Attitude {
        var to = target
        var dot = x * to.x + y * to.y + z * to.z + w * to.w
        if dot < 0 {
            to = to.negated
            dot = -dot
        }
        // Nearly parallel: acos is numerically unstable there and
        // linear interpolation is indistinguishable — normalize it back
        // onto the unit sphere.
        if dot > 0.9995 {
            return Attitude(
                x: x + (to.x - x) * fraction,
                y: y + (to.y - y) * fraction,
                z: z + (to.z - z) * fraction,
                w: w + (to.w - w) * fraction
            ).normalized
        }
        let theta = acos(min(dot, 1))
        let sinTheta = sin(theta)
        let a = sin((1 - fraction) * theta) / sinTheta
        let b = sin(fraction * theta) / sinTheta
        return Attitude(
            x: a * x + b * to.x,
            y: a * y + b * to.y,
            z: a * z + b * to.z,
            w: a * w + b * to.w
        )
    }

    /// A rotation of `degrees` about the (normalized) axis.
    static func rotation(degrees: Double, x: Double, y: Double, z: Double) -> Attitude {
        let length = (x * x + y * y + z * z).squareRoot()
        guard length > 0 else { return .identity }
        let half = degrees * .pi / 360
        let scale = sin(half) / length
        return Attitude(x: x * scale, y: y * scale, z: z * scale, w: cos(half))
    }

    /// Rotation about gravity — CoreMotion's world z axis — in
    /// degrees. The one axis `.xArbitraryZVertical` leaves arbitrary,
    /// and therefore the ONLY thing re-zero is allowed to touch.
    var headingDegrees: Double {
        atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * 180 / .pi
    }

    /// Map a CoreMotion attitude into the 3D stage's frame, ABSOLUTE
    /// against gravity: a phone lying on the desk renders a model
    /// lying on the stage; upright renders upright. `heading` is the
    /// yaw captured at connect / re-zero, defining which compass
    /// direction faces the viewer — pitch and roll are never
    /// calibrated away. `R·(q·q_up⁻¹)·R⁻¹`: relative to the upright
    /// pose at the captured heading, conjugated from CoreMotion's
    /// z-up world into the stage's y-up world. If a real device turns
    /// the wrong way on some axis, the sign flips HERE and nowhere
    /// else.
    func stagePose(headingDegrees heading: Double) -> Attitude {
        // Remove the captured heading IN THE WORLD FRAME first, so
        // "toward the viewer" is a fixed world direction; then measure
        // against the upright pose; then conjugate the whole rotation
        // from CoreMotion's z-up world into the stage's y-up world.
        // Ordering matters: heading removed on the wrong side tips a
        // lying phone about a compass-dependent axis instead of the
        // viewer's left-right axis.
        let relative = Attitude.rotation(degrees: -heading, x: 0, y: 0, z: 1)
            * self
            * Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        let basis = Attitude.rotation(degrees: -90, x: 1, y: 0, z: 0)
        return basis * relative * basis.inverse
    }

    /// Rotate a vector by this attitude — the quaternion sandwich
    /// `q v q⁻¹` in its expanded form. This is how the pose reaches
    /// both the RealityKit entity (as the same quaternion) and the
    /// screen-quad projection, so Interact clicks and the rendered
    /// model can never disagree. Never decompose an attitude into
    /// euler angles for display: the axis order won't match the
    /// scene's and the motion comes out wrong off the primary axes.
    func rotate(_ v: Vector3) -> Vector3 {
        let tx = 2 * (y * v.z - z * v.y)
        let ty = 2 * (z * v.x - x * v.z)
        let tz = 2 * (x * v.y - y * v.x)
        return Vector3(
            x: v.x + w * tx + (y * tz - z * ty),
            y: v.y + w * ty + (z * tx - x * tz),
            z: v.z + w * tz + (x * ty - y * tx)
        )
    }

    /// Equality as an *attitude*: true when the two quaternions encode
    /// the same physical pose, including the `q` / `-q` pair.
    func isApproximately(_ other: Attitude, tolerance: Double = 1e-6) -> Bool {
        let dot = x * other.x + y * other.y + z * other.z + w * other.w
        return abs(dot) >= 1 - tolerance
    }

    private var normalized: Attitude {
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        guard length > 0 else { return .identity }
        return Attitude(x: x / length, y: y / length, z: z / length, w: w / length)
    }
}
