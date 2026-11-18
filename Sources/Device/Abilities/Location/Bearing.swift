import Foundation

/// A compass direction in degrees clockwise from true north — the way a
/// `LocationWalk` is pointed, and (once locationd has watched the device
/// travel it) the `CLLocation.course` an app reads back.
///
/// Unlike `Coordinate`, this type never fails: the compass is a circle,
/// so every input is *normalised* onto [0, 360) rather than rejected.
/// That's the type's whole job — the browser's joystick hands us `atan2`
/// output, which is negative for half the circle, and a held arrow key
/// accumulates past a full turn.
///
/// Note this is a direction of *travel*, not a magnetometer reading. The
/// simulator has no magnetometer at all (`CLLocationManager
/// .headingAvailable()` is `false` there), so `CLHeading` can't be driven
/// by any of this — see `docs/features/location/README.md`.
public struct Bearing: Equatable, Sendable {
    /// Degrees clockwise from north, always in [0, 360).
    public let degrees: Double

    /// Normalise any degree value onto the compass circle: -90 → 270,
    /// 450 → 90, 360 → 0.
    public init(degrees: Double) {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        self.degrees = wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The bearing in radians, as the great-circle projection wants it.
    public var radians: Double { degrees * .pi / 180 }

    /// The nearest of the eight compass points, for a UI readout.
    /// Nearest-point rounding, not truncation — 350° reads "N", not "NW".
    public var cardinal: String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees / 45).rounded()) % points.count
        return points[index]
    }
}
