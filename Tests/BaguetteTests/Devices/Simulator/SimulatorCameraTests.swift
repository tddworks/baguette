import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// A simulator's camera: it has none of its own, so baguette gives it one
/// by injecting VirtualCamera into what it launches next.
@Suite("SimulatorCamera")
struct SimulatorCameraTests {

    private func camera() -> (SimulatorCamera, MockSimulatorInjection, MockSimulator) {
        let injection = MockSimulatorInjection()
        let sim = MockSimulator()
        given(sim).udid.willReturn("SIM-1")
        return (SimulatorCamera(simulator: sim, injection: injection), injection, sim)
    }

    @Test func `should connect a simulator's camera by injecting VirtualCamera into it`() async throws {
        let (camera, injection, _) = camera()
        given(injection).arm(dylibPath: .any, on: .any).willReturn(())

        try await camera.connect(dylibPath: "/tmp/vc.dylib")

        verify(injection).arm(dylibPath: .value("/tmp/vc.dylib"), on: .any).called(1)
    }

    @Test func `should disconnect a simulator's camera by removing the injection`() async throws {
        let (camera, injection, _) = camera()
        given(injection).disarm(dylibPath: .any, on: .any).willReturn(())

        try await camera.disconnect(dylibPath: "/tmp/vc.dylib")

        verify(injection).disarm(dylibPath: .value("/tmp/vc.dylib"), on: .any).called(1)
    }

    @Test func `should name the simulator whose camera it is`() {
        #expect(camera().0.device == "SIM-1")
    }

    @Test func `should refuse the camera of a phone on a cable, naming it`() {
        #expect(Server.cameraStopped(udid: "U", devices: routeDevices(name: "han's iPhone"))
            == #"{"type":"camera_state","ok":false,"error":"han's iPhone can't do camera"}"#)
    }

    @Test func `should answer the camera socket under the devices tree and a simulator's old one`() {
        #expect(Server.deviceRoutes("camera") == ["/devices/:udid/camera", "/simulators/:udid/camera"])
    }
}
