import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Handler-level coverage for the location routes. As with the
/// status-bar routes, we test the pure parse + dispatch helpers
/// (`parseLocationRequest`, `applyLocation`, `clearLocation`) rather than
/// the Hummingbird `Response` wrappers — every branch is driven with
/// one device's `MockLocation`.
@Suite("Server location routes")
struct LocationRoutesTests {

    // MARK: - parse

    @Test func `should read a single-point location body`() {
        #expect(Server.parseLocationRequest(json: #"{"latitude":37.3318,"longitude":-122.0312}"#)
            == .point(Coordinate(latitude: 37.3318, longitude: -122.0312)!))
    }

    @Test func `should read a route location body with its speed and distance`() {
        let json = """
        {"waypoints":[{"latitude":37.6,"longitude":-122.4},
                      {"latitude":40.6,"longitude":-73.8}],
         "speed":260,"distance":1000}
        """
        #expect(Server.parseLocationRequest(json: json) == .route(LocationRoute(
            waypoints: [
                Coordinate(latitude: 37.6, longitude: -122.4)!,
                Coordinate(latitude: 40.6, longitude: -73.8)!,
            ],
            speed: 260, distance: 1000
        )!))
    }

    @Test func `should read no location from malformed JSON`() {
        #expect(Server.parseLocationRequest(json: "not json") == nil)
    }

    @Test func `should reject an out-of-range location point`() {
        #expect(Server.parseLocationRequest(json: #"{"latitude":120,"longitude":0}"#) == nil)
    }

    @Test func `should reject a route with only one waypoint`() {
        #expect(Server.parseLocationRequest(json: #"{"waypoints":[{"latitude":1,"longitude":2}]}"#) == nil)
    }

    // MARK: - parse (walk)

    @Test func `should read a walk body carrying a bearing and speed`() {
        let json = #"{"latitude":37.3349,"longitude":-122.0090,"bearing":90,"speed":1.4}"#
        #expect(Server.parseLocationRequest(json: json) == .walk(LocationWalk(
            origin: Coordinate(latitude: 37.3349, longitude: -122.0090)!,
            bearing: Bearing(degrees: 90),
            speed: 1.4
        )!))
    }

    @Test func `should read a body with a bearing as a walk rather than a point`() {
        // A walk body carries latitude/longitude too, so the bearing has
        // to be what discriminates — otherwise every walk would silently
        // parse as a stationary point and the joystick would never move.
        let json = #"{"latitude":1,"longitude":2,"bearing":180,"speed":5}"#
        guard case .walk = Server.parseLocationRequest(json: json) else {
            Issue.record("a body with a bearing must parse as a walk, not a point")
            return
        }
    }

    @Test func `should normalise a walk's out-of-circle bearing`() {
        let json = #"{"latitude":1,"longitude":2,"bearing":-90,"speed":5}"#
        #expect(Server.parseLocationRequest(json: json) == .walk(LocationWalk(
            origin: Coordinate(latitude: 1, longitude: 2)!,
            bearing: Bearing(degrees: 270),
            speed: 5
        )!))
    }

    @Test func `should reject a walk with no speed`() {
        // Fail loud: a bearing with no speed is a half-built joystick
        // message, and defaulting it would send the device somewhere the
        // user never asked for.
        #expect(Server.parseLocationRequest(json: #"{"latitude":1,"longitude":2,"bearing":90}"#) == nil)
    }

    @Test func `should reject a walk with a non-positive speed`() {
        #expect(Server.parseLocationRequest(json: #"{"latitude":1,"longitude":2,"bearing":90,"speed":0}"#) == nil)
        #expect(Server.parseLocationRequest(json: #"{"latitude":1,"longitude":2,"bearing":90,"speed":-3}"#) == nil)
    }

    @Test func `should reject a walk from an out-of-range origin`() {
        #expect(Server.parseLocationRequest(json: #"{"latitude":120,"longitude":2,"bearing":90,"speed":5}"#) == nil)
    }

    // MARK: - apply

    @Test func `should pin the simulator to a single posted point`() async {
        let location = MockLocation()
        let host = routeDevices { $0.register(.location) { location } }
        given(location).set(.any).willReturn(())

        let outcome = await Server.applyLocation(
            udid: "U", body: #"{"latitude":1.5,"longitude":2.5}"#, devices: host
        )
        #expect(outcome == .ok)
        verify(location).set(.value(Coordinate(latitude: 1.5, longitude: 2.5)!)).called(1)
    }

    @Test func `should start a posted route on the simulator`() async {
        let location = MockLocation()
        let host = routeDevices { $0.register(.location) { location } }
        given(location).start(.any).willReturn(())

        let json = #"{"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}]}"#
        let outcome = await Server.applyLocation(udid: "U", body: json, devices: host)
        #expect(outcome == .ok)
        verify(location).start(.any).called(1)
    }

    @Test func `should walk the device along the projected route rather than pin a point`() async {
        // A walk reaches simctl as a `start` route, never a `set` — that's
        // the whole point of the vector model, since only a travelled
        // route makes locationd derive CLLocation.course.
        let location = MockLocation()
        let host = routeDevices { $0.register(.location) { location } }
        given(location).start(.any).willReturn(())

        let json = #"{"latitude":37.3349,"longitude":-122.0090,"bearing":90,"speed":25}"#
        let outcome = await Server.applyLocation(udid: "U", body: json, devices: host)

        let expected = LocationWalk(
            origin: Coordinate(latitude: 37.3349, longitude: -122.0090)!,
            bearing: Bearing(degrees: 90),
            speed: 25
        )!.route()
        #expect(outcome == .ok)
        verify(location).start(.value(expected)).called(1)
        verify(location).set(.any).called(0)
    }

    @Test func `should report a failed dispatch when simctl cannot start a walk`() async {
        let location = MockLocation()
        let host = routeDevices { $0.register(.location) { location } }
        given(location).start(.any).willThrow(LocationError.simctlFailed(status: 1))

        let json = #"{"latitude":1,"longitude":2,"bearing":90,"speed":5}"#
        #expect(await Server.applyLocation(udid: "U", body: json, devices: host) == .dispatchFailed)
    }

    @Test func `should report an unknown device when setting the location of a missing simulator`() async {
        let host = routeDevices()
        let outcome = await Server.applyLocation(
            udid: "ghost", body: #"{"latitude":1,"longitude":2}"#, devices: host
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report an invalid body when the location is malformed JSON`() async {
        let host = routeDevices { $0.register(.location) { MockLocation() } }
        #expect(await Server.applyLocation(udid: "U", body: "{", devices: host) == .invalidBody)
    }

    @Test func `should report a failed dispatch when simctl cannot set the location`() async {
        let location = MockLocation()
        let host = routeDevices { $0.register(.location) { location } }
        given(location).set(.any).willThrow(LocationError.simctlFailed(status: 1))

        let outcome = await Server.applyLocation(
            udid: "U", body: #"{"latitude":1,"longitude":2}"#, devices: host
        )
        #expect(outcome == .dispatchFailed)
    }

    // MARK: - clear

    @Test func `should clear the simulated location`() async {
        let location = MockLocation()
        let host = routeDevices { $0.register(.location) { location } }
        given(location).clear().willReturn(())

        #expect(await Server.clearLocation(udid: "U", devices: host) == .ok)
        verify(location).clear().called(1)
    }

    @Test func `should report an unknown device when clearing the location for an empty udid`() async {
        let host = routeDevices()
        #expect(await Server.clearLocation(udid: "", devices: host) == .unknownDevice)
    }
}
