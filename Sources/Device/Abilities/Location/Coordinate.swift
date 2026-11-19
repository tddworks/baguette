import Foundation

/// A validated geographic point — the unit the location surface pins a
/// simulator to. Latitude is clamped to ±90, longitude to ±180; an
/// out-of-range pair fails the initializer rather than reaching simctl.
///
/// `argument` is the pure projection to the `"<lat>,<lon>"` token simctl
/// expects after `location <udid> set`. simctl mandates `.` as the
/// decimal separator and `,` as the field separator, so the projection
/// is built from Swift's locale-independent `Double` interpolation — it
/// never routes through a locale-aware formatter that could emit a
/// decimal comma.
public struct Coordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    /// Fails when `latitude` is outside ±90 or `longitude` outside ±180.
    public init?(latitude: Double, longitude: Double) {
        guard (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Parse a `"<lat>,<lon>"` token (the CLI's waypoint spelling, and
    /// the inverse of `argument`). Fails when the token isn't exactly two
    /// dot-decimal numbers or the pair is out of range.
    public init?(token: String) {
        let parts = token.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]) else { return nil }
        self.init(latitude: lat, longitude: lon)
    }

    /// The `"<lat>,<lon>"` token simctl consumes — both as the `set`
    /// argument and as a waypoint inside a `start` route.
    public var argument: String { "\(latitude),\(longitude)" }

    /// JSON object matching the wire body the location route accepts and
    /// the browser panel posts. Numbers, not strings, so it round-trips
    /// through `JSONSerialization`.
    public var jsonString: String { "{\"latitude\":\(latitude),\"longitude\":\(longitude)}" }

    /// Mean Earth radius in metres (IUGG). The sphere is plenty for a
    /// simulator joystick: an ellipsoidal model would shift a 15 km
    /// projection by a few metres, well under the noise of a simulated
    /// GPS fix.
    public static let earthRadius = 6_371_008.8

    /// The point `metres` away along `bearing`, by the standard
    /// great-circle destination formula.
    ///
    /// Total by construction, so `LocationWalk` can project without
    /// unwrapping: `asin` can't leave [-90, 90], and the longitude is
    /// wrapped back onto [-180, 180] instead of overflowing past the
    /// antimeridian. A non-finite distance is the identity rather than a
    /// coordinate of NaN.
    public func projected(bearing: Bearing, metres: Double) -> Coordinate {
        guard metres.isFinite else { return self }

        let angular = metres / Self.earthRadius     // distance as an angle at the earth's centre
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let theta = bearing.radians

        let lat2 = asin(
            sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta)
        )
        let lon2 = lon1 + atan2(
            sin(theta) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )

        // Only wrap when the projection actually crossed the
        // antimeridian — running every longitude through the modulo
        // would cost precision on the overwhelmingly common in-range case.
        var degreesLon = lon2 * 180 / .pi
        if degreesLon > 180 || degreesLon < -180 {
            degreesLon = (degreesLon + 540).truncatingRemainder(dividingBy: 360) - 180
        }

        // Can't fail: `asin` bounds the latitude and the wrap above
        // bounds the longitude.
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: degreesLon)!
    }
}
