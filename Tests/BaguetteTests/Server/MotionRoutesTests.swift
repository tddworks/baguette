import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Handler-level coverage for the motion routes and, more importantly, for
/// the hook that lets a location walk drive motion.
///
/// Same shape as the location routes: the pure parse + dispatch helpers are
/// driven with one device's `MockMotion`, not the Hummingbird
/// `Response` wrappers.
@Suite("Server motion routes")
@MainActor
struct MotionRoutesTests {

    private struct Wiring {
        let devices: any Devices
        let motion: MockMotion
        let sessions: MotionSessions
        let captures: Captures
    }

    private final class Captures: @unchecked Sendable {
        var intents: [MotionIntent] = []
        var last: MotionIntent? { intents.last }
    }

    private func makeWiring() -> Wiring {
        let motion = MockMotion()
        let location = MockLocation()
        let captures = Captures()
        let devices = routeDevices(name: "iPhone 17 Pro") {
            $0.register(.location) { location }
            $0.register(.motion) { motion }
        }
        given(location).set(.any).willReturn(())
        given(location).start(.any).willReturn(())
        given(location).clear().willReturn(())
        given(motion).publish(.any).willProduce { intent in
            captures.intents.append(intent)
        }
        given(motion).published().willProduce { captures.last }
        given(motion).clear().willReturn(())
        return Wiring(devices: devices, motion: motion,
                      sessions: MotionSessions(),
                      captures: captures)
    }

    // MARK: - parse

    @Test func `should read a motion activity with its speed and confidence`() {
        let request = Server.parseMotionRequest(
            json: #"{"activity":"running","speed":3.6,"confidence":"medium"}"#)
        #expect(request?.kind == .running)
        #expect(request?.speed == 3.6)
        #expect(request?.confidence == .medium)
    }

    @Test func `should fall back to the activity's usual pace when no speed is given`() {
        // The browser's toggle sends only an activity; the speed it would
        // otherwise have to invent lives in one place instead.
        #expect(Server.parseMotionRequest(json: #"{"activity":"cycling"}"#)?.speed == 6)
    }

    @Test func `should classify the activity from the speed when the body carries only a speed`() {
        // How the browser arms: it posts the speed it is set to move at and
        // the kind is derived here. Duplicating MotionKind's thresholds in
        // JavaScript would put domain logic in the frontend, and the two
        // copies would drift.
        #expect(Server.parseMotionRequest(json: #"{"speed":6}"#)?.kind == .cycling)
        #expect(Server.parseMotionRequest(json: #"{"speed":1.4}"#)?.kind == .walking)
        #expect(Server.parseMotionRequest(json: #"{"speed":0}"#)?.kind == .stationary)
    }

    @Test func `should keep an explicit activity over the one its speed would suggest`() {
        // The CLI names a kind outright; that must not be re-derived.
        let request = Server.parseMotionRequest(
            json: #"{"activity":"walking","speed":13.4}"#)
        #expect(request?.kind == .walking)
        #expect(request?.speed == 13.4)
    }

    @Test func `should reject an unsupported motion confidence`() {
        // Silently downgrading an unknown word to `high` would report a
        // confidence the caller never asked for. Say no instead.
        #expect(Server.parseMotionRequest(
            json: #"{"activity":"walking","confidence":"certain"}"#) == nil)
    }

    @Test func `should reject a negative motion speed`() {
        // A negative speed classifies as `unknown`, which would arm a session
        // that reports no motion at all — indistinguishable from a bug.
        #expect(Server.parseMotionRequest(json: #"{"speed":-1}"#) == nil)
        #expect(Server.parseMotionRequest(json: #"{"activity":"walking","speed":-1}"#) == nil)
    }

    @Test func `should reject an unknown motion activity or a malformed body`() {
        #expect(Server.parseMotionRequest(json: #"{"activity":"swimming"}"#) == nil)
        #expect(Server.parseMotionRequest(json: "not json") == nil)
    }

    // MARK: - apply

    @Test func `should arm motion with the requested activity`() async {
        let w = makeWiring()

        let outcome = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking","speed":1.5}"#,
            devices: w.devices, sessions: w.sessions)

        #expect(outcome == .ok)
        #expect(w.captures.last?.kind == .walking)
        #expect(w.sessions.active(udid: "U") != nil)
    }

    @Test func `should report an unknown device when arming its motion`() async {
        // Its own mock: the shared wiring answers every udid, because a
        // single test makes several lookups.
        let outcome = await Server.applyMotion(
            udid: "nope", body: #"{"activity":"walking"}"#,
            devices: routeDevices(), sessions: MotionSessions())
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report an invalid body when the motion request is malformed`() async {
        let w = makeWiring()
        let outcome = await Server.applyMotion(
            udid: "U", body: "not json", devices: w.devices, sessions: w.sessions)
        #expect(outcome == .invalidBody)
    }

    @Test func `should find no motion state for an unknown device rather than call it idle`() async {
        // The POST and DELETE routes 404 an unknown udid; the read-back said
        // `{"active":false}`, which reads as "this device has motion off"
        // rather than "there is no such device".
        let devices = routeDevices()
        let sessions = MotionSessions()

        #expect(await Server.motionState(udid: "nope", devices: devices,
                                         sessions: sessions) == nil)
    }

    @Test func `should report a failed disarm and keep the session for a retry`() async {
        // If disarming fails, future app launches still load the dylib. An
        // API that answered `ok` there would leave motion silently injected.
        let motion = MockMotion()
        let devices = routeDevices(name: "iPhone 17 Pro") { $0.register(.motion) { motion } }
        given(motion).publish(.any).willReturn(())
        given(motion).clear().willThrow(SimctlCapture.Failure.failed(udid: "U", status: 2, output: ""))
        given(motion).published().willProduce { nil }
        let sessions = MotionSessions()
        _ = await Server.applyMotion(udid: "U", body: #"{"activity":"walking"}"#,
                                     devices: devices, sessions: sessions)

        let outcome = await Server.stopMotion(udid: "U", devices: devices,
                                              sessions: sessions)

        #expect(outcome == .dispatchFailed)
        // The session survives so the caller can retry the disarm.
        #expect(sessions.active(udid: "U") != nil)
    }

    @Test func `should park the device as stationary and forget the session when motion stops`() async {
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            devices: w.devices, sessions: w.sessions)

        let outcome = await Server.stopMotion(
            udid: "U", devices: w.devices, sessions: w.sessions)

        #expect(outcome == .ok)
        #expect(w.captures.last?.kind == .stationary)
        #expect(w.sessions.active(udid: "U") == nil)
    }

    @Test func `should park and disarm the published motion when stopping after a server restart`() async {
        let w = makeWiring()
        // What the guest already reads from the previous server's run.
        w.captures.intents.append(.stationary(startedAt: 1000, stepsBefore: 812, distanceBefore: 610))

        let outcome = await Server.stopMotion(
            udid: "U", devices: w.devices, sessions: w.sessions)

        #expect(outcome == .ok)
        #expect(w.captures.last?.kind == .stationary)
        #expect(w.captures.last?.stepsBefore == 812)
        #expect(w.captures.last?.distanceBefore == 610)
        verify(w.motion).clear().called(1)
        #expect(w.sessions.active(udid: "U") == nil)
    }

    @Test(arguments: [false, true])
    func `should keep a failed cleanup after a restart until an explicit retry succeeds`(failPublish: Bool) async {
        let motion = MockMotion()
        let devices = routeDevices { $0.register(.motion) { motion } }
        given(motion).published().willReturn(
            .stationary(startedAt: 1000, stepsBefore: 812, distanceBefore: 610))
        var reject = true
        let captures = Captures()
        given(motion).publish(.any).willProduce { intent in
            if reject && failPublish { throw SimctlCapture.Failure.failed(udid: "U", status: 2, output: "") }
            captures.intents.append(intent)
        }
        given(motion).clear().willProduce {
            if reject { throw SimctlCapture.Failure.failed(udid: "U", status: 3, output: "") }
        }
        let sessions = MotionSessions()

        #expect(await Server.stopMotion(udid: "U", devices: devices, sessions: sessions) == .dispatchFailed)
        #expect(sessions.active(udid: "U")?.lastError != nil)
        verify(motion).publish(.any).called(1)
        verify(motion).clear().called(failPublish ? 0 : 1)

        reject = false
        #expect(await Server.stopMotion(udid: "U", devices: devices, sessions: sessions) == .ok)
        #expect(captures.last?.kind == .stationary)
        #expect(captures.last?.stepsBefore == 812)
        #expect(captures.last?.distanceBefore == 610)
        #expect(sessions.active(udid: "U") == nil)
    }

    // MARK: - the location hook

    @Test func `should drive the motion activity from a walk's speed once motion is on`() async {
        // The headline: the browser keeps posting the same walk vector it
        // always did, and the activity follows from its speed.
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            devices: w.devices, sessions: w.sessions)

        let json = #"{"latitude":37.3,"longitude":-122,"bearing":90,"speed":6}"#
        _ = await Server.applyLocation(udid: "U", body: json, devices: w.devices,
                                       sessions: w.sessions)

        #expect(w.captures.last?.kind == .cycling)
    }

    @Test func `should drive no motion from a walk while motion is off`() async {
        // Motion is opt-in: moving the device must not arm a sim-wide
        // DYLD_INSERT_LIBRARIES behind the user's back.
        let w = makeWiring()

        let json = #"{"latitude":37.3,"longitude":-122,"bearing":90,"speed":6}"#
        _ = await Server.applyLocation(udid: "U", body: json, devices: w.devices,
                                       sessions: w.sessions)

        #expect(w.captures.intents.isEmpty)
        verify(w.motion).publish(.any).called(0)
    }

    @Test func `should drive the motion activity from a route's own speed`() async {
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            devices: w.devices, sessions: w.sessions)

        let json = """
        {"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":20}
        """
        _ = await Server.applyLocation(udid: "U", body: json, devices: w.devices,
                                       sessions: w.sessions)

        #expect(w.captures.last?.kind == .automotive)
    }

    @Test func `should park motion as stationary when the location is pinned to a point`() async {
        // Releasing the joystick posts a bare point, which is exactly the
        // moment the device stops travelling — `course` drops to -1 and the
        // activity should stop claiming movement too.
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            devices: w.devices, sessions: w.sessions)

        _ = await Server.applyLocation(udid: "U", body: #"{"latitude":1,"longitude":2}"#,
                                       devices: w.devices, sessions: w.sessions)

        #expect(w.captures.last?.kind == .stationary)
    }

    @Test func `should park motion as stationary when the location is cleared`() async {
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            devices: w.devices, sessions: w.sessions)

        _ = await Server.clearLocation(udid: "U", devices: w.devices,
                                       sessions: w.sessions)

        #expect(w.captures.last?.kind == .stationary)
    }
}
