import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the motion routes and, more importantly, for
/// the hook that lets a location walk drive motion.
///
/// Same shape as the location routes: the pure parse + dispatch helpers are
/// driven with `MockSimulators` + `MockMotion`, not the Hummingbird
/// `Response` wrappers.
@Suite("Server motion routes")
@MainActor
struct MotionRoutesTests {

    private struct Wiring {
        let simulators: MockSimulators
        let sim: MockSimulator
        let motion: MockMotion
        let sessions: MotionSessions
        let captures: Captures
    }

    private final class Captures: @unchecked Sendable {
        var intents: [MotionIntent] = []
        var last: MotionIntent? { intents.last }
    }

    private func makeWiring() -> Wiring {
        let simulators = MockSimulators()
        let sim = MockSimulator()
        let motion = MockMotion()
        let location = MockLocation()
        let captures = Captures()
        // One stub only: registering a second `find` here would be consumed
        // by the second lookup in the same test (applyMotion, then the
        // location hook), and the device would go "missing" mid-test.
        given(simulators).find(udid: .any).willReturn(sim)
        given(sim).udid.willReturn("U")
        given(sim).name.willReturn("iPhone 17 Pro")
        given(sim).location().willReturn(location)
        given(location).set(.any).willReturn(())
        given(location).start(.any).willReturn(())
        given(location).clear().willReturn(())
        given(motion).publish(.any, on: .any).willProduce { intent, _ in
            captures.intents.append(intent)
        }
        given(motion).clear(on: .any).willReturn(())
        return Wiring(simulators: simulators, sim: sim, motion: motion,
                      sessions: MotionSessions(makeMotion: { _ in motion }),
                      captures: captures)
    }

    // MARK: - parse

    @Test func `parseMotionRequest reads an activity with speed and confidence`() {
        let request = Server.parseMotionRequest(
            json: #"{"activity":"running","speed":3.6,"confidence":"medium"}"#)
        #expect(request?.kind == .running)
        #expect(request?.speed == 3.6)
        #expect(request?.confidence == .medium)
    }

    @Test func `parseMotionRequest falls back to the kind's usual pace`() {
        // The browser's toggle sends only an activity; the speed it would
        // otherwise have to invent lives in one place instead.
        #expect(Server.parseMotionRequest(json: #"{"activity":"cycling"}"#)?.speed == 6)
    }

    @Test func `parseMotionRequest classifies a body that carries only a speed`() {
        // How the browser arms: it posts the speed it is set to move at and
        // the kind is derived here. Duplicating MotionKind's thresholds in
        // JavaScript would put domain logic in the frontend, and the two
        // copies would drift.
        #expect(Server.parseMotionRequest(json: #"{"speed":6}"#)?.kind == .cycling)
        #expect(Server.parseMotionRequest(json: #"{"speed":1.4}"#)?.kind == .walking)
        #expect(Server.parseMotionRequest(json: #"{"speed":0}"#)?.kind == .stationary)
    }

    @Test func `an explicit activity wins over the speed's classification`() {
        // The CLI names a kind outright; that must not be re-derived.
        let request = Server.parseMotionRequest(
            json: #"{"activity":"walking","speed":13.4}"#)
        #expect(request?.kind == .walking)
        #expect(request?.speed == 13.4)
    }

    @Test func `parseMotionRequest rejects an unsupported confidence`() {
        // Silently downgrading an unknown word to `high` would report a
        // confidence the caller never asked for. Say no instead.
        #expect(Server.parseMotionRequest(
            json: #"{"activity":"walking","confidence":"certain"}"#) == nil)
    }

    @Test func `parseMotionRequest rejects a negative speed`() {
        // A negative speed classifies as `unknown`, which would arm a session
        // that reports no motion at all — indistinguishable from a bug.
        #expect(Server.parseMotionRequest(json: #"{"speed":-1}"#) == nil)
        #expect(Server.parseMotionRequest(json: #"{"activity":"walking","speed":-1}"#) == nil)
    }

    @Test func `parseMotionRequest rejects an unknown activity`() {
        #expect(Server.parseMotionRequest(json: #"{"activity":"swimming"}"#) == nil)
        #expect(Server.parseMotionRequest(json: "not json") == nil)
    }

    // MARK: - apply

    @Test func `applyMotion publishes the requested activity`() async {
        let w = makeWiring()

        let outcome = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking","speed":1.5}"#,
            simulators: w.simulators, sessions: w.sessions)

        #expect(outcome == .ok)
        #expect(w.captures.last?.kind == .walking)
        #expect(w.sessions.active(udid: "U") != nil)
    }

    @Test func `applyMotion reports an unknown device`() async {
        // Its own mock: the shared wiring answers every udid, because a
        // single test makes several lookups.
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        let outcome = await Server.applyMotion(
            udid: "nope", body: #"{"activity":"walking"}"#,
            simulators: simulators, sessions: MotionSessions(makeMotion: { _ in MockMotion() }))
        #expect(outcome == .unknownDevice)
    }

    @Test func `applyMotion reports a malformed body`() async {
        let w = makeWiring()
        let outcome = await Server.applyMotion(
            udid: "U", body: "not json", simulators: w.simulators, sessions: w.sessions)
        #expect(outcome == .invalidBody)
    }

    @Test func `motion state reports an unknown device rather than an idle one`() async {
        // The POST and DELETE routes 404 an unknown udid; the read-back said
        // `{"active":false}`, which reads as "this device has motion off"
        // rather than "there is no such device".
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        let sessions = MotionSessions(makeMotion: { _ in MockMotion() })

        #expect(await Server.motionState(udid: "nope", simulators: simulators,
                                         sessions: sessions) == nil)
    }

    @Test func `a failed disarm is reported rather than swallowed`() async {
        // If disarming fails, future app launches still load the dylib. An
        // API that answered `ok` there would leave motion silently injected.
        let simulators = MockSimulators()
        let sim = MockSimulator()
        given(simulators).find(udid: .any).willReturn(sim)
        given(sim).udid.willReturn("U")
        given(sim).name.willReturn("iPhone 17 Pro")
        let motion = MockMotion()
        given(motion).publish(.any, on: .any).willReturn(())
        given(motion).clear(on: .any).willThrow(SimctlCapture.Failure.failed(udid: "U", status: 2, output: ""))
        let sessions = MotionSessions(makeMotion: { _ in motion })
        _ = await Server.applyMotion(udid: "U", body: #"{"activity":"walking"}"#,
                                     simulators: simulators, sessions: sessions)

        let outcome = await Server.stopMotion(udid: "U", simulators: simulators,
                                              sessions: sessions)

        #expect(outcome == .dispatchFailed)
        // The session survives so the caller can retry the disarm.
        #expect(sessions.active(udid: "U") != nil)
    }

    @Test func `stopMotion parks the device and forgets the session`() async {
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            simulators: w.simulators, sessions: w.sessions)

        let outcome = await Server.stopMotion(
            udid: "U", simulators: w.simulators, sessions: w.sessions)

        #expect(outcome == .ok)
        #expect(w.captures.last?.kind == .stationary)
        #expect(w.sessions.active(udid: "U") == nil)
    }

    // MARK: - the location hook

    @Test func `a walk drives motion once motion is on`() async {
        // The headline: the browser keeps posting the same walk vector it
        // always did, and the activity follows from its speed.
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            simulators: w.simulators, sessions: w.sessions)

        let json = #"{"latitude":37.3,"longitude":-122,"bearing":90,"speed":6}"#
        _ = await Server.applyLocation(udid: "U", body: json, simulators: w.simulators,
                                       sessions: w.sessions)

        #expect(w.captures.last?.kind == .cycling)
    }

    @Test func `a walk drives nothing while motion is off`() async {
        // Motion is opt-in: moving the device must not arm a sim-wide
        // DYLD_INSERT_LIBRARIES behind the user's back.
        let w = makeWiring()

        let json = #"{"latitude":37.3,"longitude":-122,"bearing":90,"speed":6}"#
        _ = await Server.applyLocation(udid: "U", body: json, simulators: w.simulators,
                                       sessions: w.sessions)

        #expect(w.captures.intents.isEmpty)
        verify(w.motion).publish(.any, on: .any).called(0)
    }

    @Test func `a route drives motion from its own speed`() async {
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            simulators: w.simulators, sessions: w.sessions)

        let json = """
        {"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":20}
        """
        _ = await Server.applyLocation(udid: "U", body: json, simulators: w.simulators,
                                       sessions: w.sessions)

        #expect(w.captures.last?.kind == .automotive)
    }

    @Test func `pinning a point parks motion as stationary`() async {
        // Releasing the joystick posts a bare point, which is exactly the
        // moment the device stops travelling — `course` drops to -1 and the
        // activity should stop claiming movement too.
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            simulators: w.simulators, sessions: w.sessions)

        _ = await Server.applyLocation(udid: "U", body: #"{"latitude":1,"longitude":2}"#,
                                       simulators: w.simulators, sessions: w.sessions)

        #expect(w.captures.last?.kind == .stationary)
    }

    @Test func `clearing the location parks motion too`() async {
        let w = makeWiring()
        _ = await Server.applyMotion(
            udid: "U", body: #"{"activity":"walking"}"#,
            simulators: w.simulators, sessions: w.sessions)

        _ = await Server.clearLocation(udid: "U", simulators: w.simulators,
                                       sessions: w.sessions)

        #expect(w.captures.last?.kind == .stationary)
    }
}
