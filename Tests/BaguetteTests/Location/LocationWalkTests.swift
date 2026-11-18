import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `LocationWalk` — the joystick's vector
/// (origin + bearing + speed) and its projection onto the
/// `LocationRoute` simctl already understands.
///
/// The mechanism this type exists to serve: `simctl location set` pins a
/// point with `course == -1` (no direction of travel), so a joystick
/// built on repeated `set` calls could never drive `CLLocation.course`.
/// A two-waypoint `start` route makes locationd *derive* course and
/// speed from real interpolated motion — verified against a booted sim,
/// where a due-east route reported `Speed,25.00,Course,90.00`. So a walk
/// is modelled as a vector and projected into a route whose far waypoint
/// lies along the bearing.
@Suite("LocationWalk")
struct LocationWalkTests {

    /// Apple Park — the same friendly default the browser panel centres on.
    private let origin = Coordinate(latitude: 37.3349, longitude: -122.0090)!

    @Test func `should refuse a walk when its speed is not positive`() {
        // A standing-still walk isn't a walk — it's a `set`.
        #expect(LocationWalk(origin: origin, bearing: Bearing(degrees: 0), speed: 0) == nil)
        #expect(LocationWalk(origin: origin, bearing: Bearing(degrees: 0), speed: -5) == nil)
    }

    @Test func `should accept a walk at a positive speed`() {
        #expect(LocationWalk(origin: origin, bearing: Bearing(degrees: 0), speed: 1.4) != nil)
    }

    @Test func `should plan a two-waypoint route starting at the walk's origin`() {
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 90), speed: 25)!
        let route = walk.route(horizon: 600)
        #expect(route.waypoints.count == 2)
        #expect(route.waypoints.first == origin)
    }

    @Test func `should end the route the walk's distance ahead along its bearing`() {
        // Due east at 25 m/s over a 600 s horizon = 15 km of easting.
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 90), speed: 25)!
        let end = walk.route(horizon: 600).waypoints.last!
        #expect(end.longitude > origin.longitude)
        #expect(abs(end.longitude - (-121.839339)) < 1e-5)
    }

    @Test func `should shed latitude as a great circle does when walking due east`() {
        // Not a rhumb line: a great circle pointed *exactly* east is at
        // its vertex — its northernmost point — so it loses latitude in
        // either direction. Over 15 km from 37°N that's 1.21e-4° ≈ 13 m
        // of southing, which is why the far waypoint isn't at the origin's
        // latitude. It costs ~0.05° of course error at this horizon,
        // far below what a simulated GPS fix resolves.
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 90), speed: 25)!
        let end = walk.route(horizon: 600).waypoints.last!
        #expect(end.latitude < origin.latitude)
        #expect(abs(end.latitude - 37.334779) < 1e-5)
    }

    @Test func `should carry the walk's speed onto the route so locationd derives it`() {
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 0), speed: 1.4)!
        #expect(walk.route(horizon: 600).speed == 1.4)
    }

    @Test func `should dead-reckon the walker's position after a span of travel`() {
        // 1 km due north at 10 m/s takes 100 s.
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 0), speed: 10)!
        let after = walk.position(after: 100)
        #expect(abs(after.latitude - 37.343893) < 1e-5)
        #expect(abs(after.longitude - origin.longitude) < 1e-9)
    }

    @Test func `should stand still at the origin when no time has elapsed`() {
        // Tolerance, not equality: the projection round-trips through
        // radians and `asin(sin(φ))`, so the identity case lands within a
        // ulp or two of the origin rather than bit-exactly on it.
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 123), speed: 10)!
        let still = walk.position(after: 0)
        #expect(abs(still.latitude - origin.latitude) < 1e-12)
        #expect(abs(still.longitude - origin.longitude) < 1e-12)
    }

    @Test func `should end the route where the walker is dead-reckoned to be at the horizon`() {
        // The route's far waypoint IS the walk's position at the horizon —
        // the browser's locally dead-reckoned pin and the device's actual
        // interpolated track are the same line, so they can't disagree.
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 217), speed: 8)!
        #expect(walk.route(horizon: 600).waypoints.last == walk.position(after: 600))
    }

    @Test func `should hand simctl a speed flag and two waypoints to start the walk`() {
        let walk = LocationWalk(origin: origin, bearing: Bearing(degrees: 90), speed: 25)!
        let args = walk.route(horizon: 600).startArguments
        #expect(args.first == "--speed=25")
        #expect(args.count == 3)                       // flag + two waypoints
        #expect(args[1] == "37.3349,-122.009")
    }
}
