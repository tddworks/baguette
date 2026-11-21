import Testing
@testable import BaguetteDevice

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

/// When a still screen's last frame is sent again: on a beat anchored to the
/// clock, so a refresh that runs late doesn't push every later one back.
@Suite("RefreshCadence")
struct RefreshCadenceTests {
    @Test func `should keep its beat when a refresh runs late`() {
        var cadence = RefreshCadence(fps: 10)

        let first = cadence.next(at: 0)
        let afterLate = cadence.next(at: 0.103)

        #expect(near(first, 0.1))
        #expect(near(afterLate, 0.2))
    }

    @Test func `should skip a beat it missed rather than catch up`() {
        var cadence = RefreshCadence(fps: 10)
        _ = cadence.next(at: 0)

        #expect(near(cadence.next(at: 0.35), 0.4))
    }

    @Test func `should start a new beat when the frame rate changes`() {
        var cadence = RefreshCadence(fps: 10)
        _ = cadence.next(at: 0)

        cadence.fps = 20

        #expect(near(cadence.next(at: 0.12), 0.17))
    }
}
