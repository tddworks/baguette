import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Coverage for `MotionSessions` — the per-device motion state the
/// server's stateless route handlers reach through.
///
/// The important behaviour is the asymmetry: starting motion **creates** a
/// session, while a location walk only ever asks for one that already
/// exists. That's what keeps motion opt-in — moving the device must never
/// arm a sim-wide `DYLD_INSERT_LIBRARIES` as a side effect.
@Suite("MotionSessions")
@MainActor
struct MotionSessionsTests {

    private func makeSessions() -> (MotionSessions, MockMotion) {
        let motion = MockMotion()
        given(motion).publish(.any).willReturn(())
        given(motion).clear().willReturn(())
        return (MotionSessions(), motion)
    }

    @Test func `should have no session until motion is started`() {
        let (sessions, _) = makeSessions()
        #expect(sessions.active(udid: "U") == nil)
    }

    @Test func `should reach a session once motion is started`() {
        let (sessions, motion) = makeSessions()
        let created = sessions.session(for: "U", motion: { motion })
        #expect(sessions.active(udid: "U") === created)
    }

    @Test func `should reuse one session per device so the ledger survives`() {
        // A second `motion` POST must not reset the pedometer — the running
        // totals live on the session.
        let (sessions, motion) = makeSessions()
        #expect(sessions.session(for: "U", motion: { motion }) === sessions.session(for: "U", motion: { motion }))
    }

    @Test func `should keep separate sessions per device`() {
        let (sessions, motion) = makeSessions()
        #expect(sessions.session(for: "U", motion: { motion }) !== sessions.session(for: "V", motion: { motion }))
    }

    @Test func `should drop the session when motion ends so a walk stops driving it`() {
        let (sessions, motion) = makeSessions()
        _ = sessions.session(for: "U", motion: { motion })
        sessions.end(udid: "U")
        #expect(sessions.active(udid: "U") == nil)
    }
}
