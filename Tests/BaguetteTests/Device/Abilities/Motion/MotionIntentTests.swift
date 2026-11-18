import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Coverage for `MotionIntent` — the payload baguette publishes into the
/// simulator and the injected dylib reads back.
///
/// It is an **intent**, not a sample: it says "the device is running at
/// 3.6 m/s, it started at T, and N steps had already accrued before this
/// leg". The dylib integrates from that. Streaming samples would be
/// impossible — a pedometer accumulates monotonically and
/// `CMMotionManager` delivers at up to 100 Hz.
///
/// Every number the dylib needs is pre-resolved here, including the raw
/// CoreMotion enum values, so the ObjC side carries no policy it could
/// disagree with.
@Suite("MotionIntent")
struct MotionIntentTests {

    private let running = MotionIntent(
        kind: .running,
        confidence: .high,
        speed: 3.6,
        startedAt: 1000,
        stepsBefore: 0,
        distanceBefore: 0
    )

    @Test func `should publish the intent as sorted-key JSON with the profile resolved`() throws {
        // Sorted keys make this byte-comparable, the same discipline
        // `SharedFrameLayout.encodeHeader` holds for the camera's binary
        // header. The dylib parses this with NSJSONSerialization.
        let json = String(decoding: try running.encoded(), as: UTF8.self)
        #expect(json == """
            {"activityType":8,"confidence":2,"distanceBefore":0,"kind":"running",\
            "profile":{"cadenceHz":3,"gaitAmplitude":0.8,"strideMetres":1.2},\
            "speed":3.6,"startedAt":1000,"stepsBefore":0}
            """)
    }

    @Test func `should resolve the Core Motion activity and confidence values so the dylib maps nothing`() {
        // `kind` is there for a human reading the file; `activityType` and
        // `confidence` are what the dylib actually copies into the struct.
        #expect(running.activityType == 8)
        #expect(running.confidence.coreMotionValue == 2)
    }

    @Test func `should derive the gait profile from the kind and speed given`() {
        #expect(running.profile.strideMetres == 1.2)
        #expect(running.profile.cadenceHz == 3)
    }

    @Test func `should read back the same intent it published`() throws {
        let decoded = try MotionIntent(decoding: try running.encoded())
        #expect(decoded == running)
    }

    @Test func `should report stationary and accrue nothing, keeping earlier totals, when motion is cleared`() {
        // What `motion stop` / `location clear` publishes: an app keeps
        // reading, and reads "not moving" rather than stale movement.
        let idle = MotionIntent.stationary(startedAt: 1000, stepsBefore: 812,
                                          distanceBefore: 610)
        #expect(idle.kind == .stationary)
        #expect(idle.profile.cadenceHz == 0)
        // The totals already walked must survive — a pedometer is
        // cumulative, so standing still cannot reset the day's steps.
        #expect(idle.stepsBefore == 812)
        #expect(idle.distanceBefore == 610)
    }
}
