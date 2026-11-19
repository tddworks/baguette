import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `POST /simulators/<udid>/hinge` and `baguette hinge`: a pose by name —
/// Device Hub's three — or an angle, swept over a duration.
@Suite("HingeCommand")
struct HingeCommandTests {
    @Test func `should take a pose by name as Device Hub's angle for it`() throws {
        #expect(try HingeCommand.parse(pose: "closed", angle: nil, duration: nil).degrees == 0)
        #expect(try HingeCommand.parse(pose: "open", angle: nil, duration: nil).degrees == 130)
        #expect(try HingeCommand.parse(pose: "flat", angle: nil, duration: nil).degrees == 180)
    }

    @Test func `should take an angle as given and reject one outside the hinge's range`() throws {
        let command = try HingeCommand.parse(pose: nil, angle: "95.5", duration: "1.2")
        #expect(command == HingeCommand(degrees: 95.5, duration: 1.2))
        #expect(throws: HingeCommandError.angleOutOfRange) {
            try HingeCommand.parse(pose: nil, angle: "181", duration: nil)
        }
    }

    @Test func `should sweep over Device Hub's time unless told otherwise, and reject a negative duration`() throws {
        #expect(try HingeCommand.parse(pose: "open", angle: nil, duration: nil).duration == HingeCommand.defaultDuration)
        #expect(throws: HingeCommandError.invalidDuration) {
            try HingeCommand.parse(pose: "open", angle: nil, duration: "-1")
        }
    }

    /// Device Hub sweeps in under a second. A sweep of more than a minute
    /// is a slip, and a long enough one stopped `serve`.
    @Test func `should reject a sweep longer than a minute`() throws {
        #expect(try HingeCommand.parse(pose: "open", angle: nil, duration: "60").duration == 60)
        for duration in ["60.1", "1e300"] {
            #expect(throws: HingeCommandError.invalidDuration) {
                try HingeCommand.parse(pose: "open", angle: nil, duration: duration)
            }
        }
    }

    @Test func `should require a pose or an angle, and reject a pose other than the three`() {
        #expect(throws: HingeCommandError.missingTarget) {
            try HingeCommand.parse(pose: nil, angle: nil, duration: nil)
        }
        #expect(throws: HingeCommandError.unknownPose("tent")) {
            try HingeCommand.parse(pose: "tent", angle: nil, duration: nil)
        }
    }
}
