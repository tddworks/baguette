import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// CarPlay's compositor often goes idle on a static home screen, so
/// callback-only capture starves the browser. An idle floor keeps
/// emitting frames while the surface is live.
@Suite("ScreenIdleFloor")
struct ScreenIdleFloorTests {
    @Test func `should keep a CarPlay stream alive at an idle frame floor`() {
        #expect(ScreenIdleFloor.isEnabled(for: .carPlay))
    }

    @Test func `should keep a phone stream alive at an idle frame floor too`() {
        // Phone maps/animations usually callback, but a quiet lock
        // screen still needs a floor — same policy as the spike.
        #expect(ScreenIdleFloor.isEnabled(for: .phone))
    }

    @Test func `should hold the idle frame floor at five frames per second`() {
        #expect(ScreenIdleFloor.intervalNanoseconds == 200_000_000)
    }
}
