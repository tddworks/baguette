import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("DeviceState")
struct DeviceStateTests {
    @Test func `should accept gestures and streams when the device is ready`() {
        #expect(DeviceState.ready.canAcceptInput)
    }

    @Test func `should refuse gestures and streams when the device is off, starting or unavailable`() {
        #expect(!DeviceState.off.canAcceptInput)
        #expect(!DeviceState.starting.canAcceptInput)
        #expect(!DeviceState.unavailable(reason: "locked").canAcceptInput)
    }

    @Test func `should read a booted simulator as ready`() {
        #expect(SimulatorState.booted.deviceState == .ready)
    }

    @Test func `should read a simulator being created or booting as starting`() {
        #expect(SimulatorState.creating.deviceState == .starting)
        #expect(SimulatorState.booting.deviceState == .starting)
    }

    @Test func `should read a simulator shut down or shutting down as off`() {
        #expect(SimulatorState.shutdown.deviceState == .off)
        #expect(SimulatorState.shuttingDown.deviceState == .off)
    }
}
