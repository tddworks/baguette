import Foundation

/// A joystick's vector — "from here, head that way, at that speed". The
/// unit the browser's Walk mode sends, and the thing that becomes a
/// `LocationRoute` before it reaches simctl.
///
/// ## Why a walk is modelled as a vector, not a position
///
/// The obvious joystick — push the stick, `simctl location set` a new
/// point every tick — fails twice over. Each `set` spawn costs ~277 ms,
/// capping the tick rate near 3.6 Hz (visibly jerky), and worse, a
/// `set` pins a *stationary* point: locationd reports `course = -1` and
/// `speed = -1`, so no app could ever read a direction of travel.
///
/// A two-waypoint `start` route fixes both. It's fire-and-forget — the
/// spawn returns in ~430 ms while the *daemon* interpolates smoothly for
/// as long as the route lasts — and because the device genuinely travels
/// the leg, locationd **derives** course and speed from the motion and
/// hands them to `CLLocation`. Verified against a booted iOS 26 sim: a
/// due-east route at 25 m/s reports `Speed,25.00,Course,90.00`.
///
/// So the joystick never sends positions. It sends this vector; the
/// vector projects a waypoint over the horizon along its bearing; and
/// the device walks toward it. A direction change re-issues a fresh
/// route (locationd retargets in ~200 ms, mid-flight, no glitch);
/// releasing the stick sends a plain `set`, whose `course = -1` is
/// exactly the right "stopped" semantic.
public struct LocationWalk: Equatable, Sendable {
    /// Where the walk starts — the device's position at the moment the
    /// vector changed.
    public var origin: Coordinate
    /// The direction of travel, which becomes `CLLocation.course`.
    public var bearing: Bearing
    /// Metres per second, which becomes `CLLocation.speed`.
    public var speed: Double

    /// How far ahead to project the route's far waypoint, in seconds of
    /// travel. Long enough that a held stick keeps walking (10 minutes)
    /// without projecting so far that a great circle's bearing drifts
    /// off the one asked for — at 25 m/s this is 15 km, where the
    /// divergence from the intended course is under 0.05°.
    public static let defaultHorizon: TimeInterval = 600

    /// Fails when `speed` isn't a positive, finite number. Standing still
    /// isn't a walk — it's a `set` — and a non-finite speed would
    /// project a waypoint to nowhere.
    public init?(origin: Coordinate, bearing: Bearing, speed: Double) {
        // `speed > 0` rejects NaN too: every comparison against NaN is
        // false, so the guard catches it without a separate check.
        guard speed > 0, speed.isFinite else { return nil }
        self.origin = origin
        self.bearing = bearing
        self.speed = speed
    }

    /// Where the walk has reached after `seconds` of travel — the pure
    /// dead-reckoning the browser mirrors in JS to advance its pin
    /// between sends.
    public func position(after seconds: TimeInterval) -> Coordinate {
        origin.projected(bearing: bearing, metres: speed * seconds)
    }

    /// Project the vector onto the two-waypoint route simctl already
    /// understands: origin → wherever the walk reaches at the horizon.
    ///
    /// The far waypoint IS `position(after: horizon)`, so the browser's
    /// locally dead-reckoned pin and the device's interpolated track
    /// trace the same line and can't disagree.
    public func route(horizon: TimeInterval = LocationWalk.defaultHorizon) -> LocationRoute {
        // Can't fail: `LocationRoute` needs two-or-more waypoints (we
        // hand it exactly two) and a positive speed (guaranteed by this
        // type's own initialiser).
        LocationRoute(waypoints: [origin, position(after: horizon)], speed: speed)!
    }
}
