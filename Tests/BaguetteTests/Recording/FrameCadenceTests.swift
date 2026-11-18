import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The simulator delivers a frame whenever the screen changes, which is
/// up to 60 times a second. A recording asked for 30 fps keeps every
/// other one — the cadence is what decides.
@Suite("FrameCadence")
struct FrameCadenceTests {

    /// `accepts` is mutating, so `#expect` can't call it in place —
    /// run the arrivals through and report which ones were kept.
    private func kept(fps: Int, arrivals: [Double]) -> [Double] {
        var cadence = FrameCadence(fps: fps)
        return arrivals.filter { cadence.accepts($0) }
    }

    @Test func `should always keep the first frame of a recording`() {
        #expect(kept(fps: 30, arrivals: [7.5]) == [7.5])
    }

    @Test func `should drop frames that arrive faster than the requested rate`() {
        #expect(kept(fps: 10, arrivals: [0, 0.02, 0.04, 0.1, 0.11, 0.2]) == [0, 0.1, 0.2])
    }

    @Test func `should shift the cadence rather than catch up when a frame arrives late`() {
        // The slot after 0.37 opens 0.1 s later, not on an absolute grid.
        #expect(kept(fps: 10, arrivals: [0, 0.37, 0.42, 0.48]) == [0, 0.37, 0.48])
    }

    @Test func `should keep a frame that arrives a hair early`() {
        let interval = 1.0 / 60.0
        #expect(kept(fps: 60, arrivals: [0, interval - 0.0005]) == [0, interval - 0.0005])
    }

    @Test func `should keep every frame rather than divide by zero when the frame rate is zero`() {
        #expect(FrameCadence(fps: 0).interval == 0)
        #expect(kept(fps: 0, arrivals: [0, 0.001, 0.002]) == [0, 0.001, 0.002])
    }

    @Test func `should space frames by the reciprocal of the requested rate`() {
        #expect(FrameCadence(fps: 30).interval == 1.0 / 30.0)
    }
}
