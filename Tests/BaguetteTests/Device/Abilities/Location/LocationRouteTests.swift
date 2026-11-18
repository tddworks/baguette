import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `LocationRoute.startArguments` — the argv tail
/// handed to `xcrun simctl location <udid> start …`. simctl interpolates
/// a moving location between the waypoints; speed / distance / interval
/// tune how fast and how often updates fire. At least two waypoints are
/// required (one point is a `set`, not a route).
@Suite("LocationRoute")
struct LocationRouteTests {

    private func sf() -> Coordinate { Coordinate(latitude: 37.629538, longitude: -122.395733)! }
    private func nyc() -> Coordinate { Coordinate(latitude: 40.628083, longitude: -73.768254)! }

    @Test func `should refuse a route when it has fewer than two waypoints`() {
        #expect(LocationRoute(waypoints: []) == nil)
        #expect(LocationRoute(waypoints: [sf()]) == nil)
        #expect(LocationRoute(waypoints: [sf(), nyc()]) != nil)
    }

    @Test func `should pass only the waypoints to simctl when the route sets no speed, distance or interval`() {
        let route = LocationRoute(waypoints: [sf(), nyc()])
        #expect(route?.startArguments == ["37.629538,-122.395733", "40.628083,-73.768254"])
    }

    @Test func `should pass speed, distance and interval as equals-form flags ahead of the waypoints`() {
        let route = LocationRoute(
            waypoints: [sf(), nyc()],
            speed: 260,
            distance: 1000,
            interval: 2.5
        )
        #expect(route?.startArguments == [
            "--speed=260",
            "--distance=1000",
            "--interval=2.5",
            "37.629538,-122.395733",
            "40.628083,-73.768254",
        ])
    }

    @Test func `should refuse a route when its speed is not positive`() {
        #expect(LocationRoute(waypoints: [sf(), nyc()], speed: 0) == nil)
        #expect(LocationRoute(waypoints: [sf(), nyc()], speed: -5) == nil)
    }
}
