import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// A sweep baguette plays on the hinge moves it the way `DeviceHubControls
/// sweep` does: one sample every 60 Hz frame with Device Hub's ease-out,
/// the first step at once and the last exactly on the target.
@Suite("HingeSweep")
struct HingeSweepTests {
    private let open = HingeSweep(from: 180, to: 130, duration: 0.8)

    @Test func `should step along DeviceHubControls' ease-out one sample a frame`() {
        // Read back from the guest during `sweep 180 130 800`.
        #expect(abs(open.degrees(after: 0) - 176.88) < 0.01)
        #expect(abs(open.degrees(after: 1.0 / 60) - 173.88) < 0.01)
        #expect(abs(open.degrees(after: 2.0 / 60) - 171.02) < 0.01)
        #expect(abs(open.degrees(after: 3.0 / 60) - 168.29) < 0.01)
    }

    @Test func `should hold each sample until the next frame`() {
        #expect(open.degrees(after: 0.01) == open.degrees(after: 0))
    }

    @Test func `should land exactly on the target with its last sample and stay there`() {
        // 0.8 s is 47 frames of 16.667 ms; the last goes out 46 frames in.
        #expect(open.settlesAfter == 46 * HingeSweep.frameInterval)
        #expect(open.degrees(after: open.settlesAfter) == 130)
        #expect(open.degrees(after: open.settlesAfter - 0.01) > 130)
        #expect(open.degrees(after: 5) == 130)
    }

    /// `POST /hinge` takes any finite duration; counting its frames must
    /// not stop the server.
    @Test func `should play a sweep too long to count in frames as one that never settles`() {
        let endless = HingeSweep(from: 0, to: 130, duration: 1e300)
        #expect(endless.degrees(after: 0) < 1)
        #expect(!endless.hasSettled(after: 3600))
    }

    @Test func `should go straight to the target when there is no time to sweep`() {
        let jump = HingeSweep(from: 0, to: 72, duration: 0)
        #expect(jump.settlesAfter == 0)
        #expect(jump.degrees(after: 0) == 72)
    }
}
