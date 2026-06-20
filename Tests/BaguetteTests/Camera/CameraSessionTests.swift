import Testing
import Foundation
import Mockable
@testable import BaguetteCore

/// Behaviour spec for the CameraSession state machine. The session
/// owns three collaborators (capture, sink, injection). Tests inject
/// the auto-generated `MockXxx` and assert on returned state.
@Suite("CameraSession")
@MainActor
struct CameraSessionTests {

    private static let device = CameraDevice(uid: "u-1", name: "FaceTime", isDefault: true)

    /// Captures `start(device:onFrame:)` callbacks so the test can
    /// fire frames through the orchestrator on demand.
    final class Captures: @unchecked Sendable {
        var onFrame: (@Sendable (CameraFrame) -> Void)?
    }

    private struct Wiring {
        let session: CameraSession
        let capture: MockCameraCapture
        let sink: MockCameraFrameSink
        let injection: MockSimulatorInjection
        let sim: MockSimulator
        let captures: Captures
    }

    /// Bare wiring — mocks are created but NOT pre-stubbed. Each test
    /// configures only the behaviours it needs so overrides don't
    /// collide with FIFO matching.
    private func makeWiring() -> Wiring {
        let capture = MockCameraCapture()
        let sink = MockCameraFrameSink()
        let injection = MockSimulatorInjection()
        let sim = MockSimulator()
        given(sim).udid.willReturn("sim-U")
        let captures = Captures()
        let session = CameraSession(capture: capture, sink: sink, injection: injection)
        return Wiring(
            session: session, capture: capture, sink: sink,
            injection: injection, sim: sim, captures: captures
        )
    }

    /// Helper for happy-path stubs — call from each test that wants
    /// the capture to succeed and record the onFrame callback.
    private func stubHappyCapture(_ w: Wiring) {
        given(w.capture).start(device: .any, onFrame: .any).willProduce { _, onFrame in
            w.captures.onFrame = onFrame
        }
    }

    @Test func `starts in idle phase with no error and zero fps`() {
        let w = makeWiring()
        #expect(w.session.phase == .idle)
        #expect(w.session.fps == 0)
        #expect(w.session.lastError == nil)
    }

    @Test func `start arms the dylib and kicks off capture`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        stubHappyCapture(w)

        await w.session.start(device: Self.device, on: w.sim, dylibPath: "/tmp/vc.dylib")

        verify(w.injection).arm(dylibPath: .value("/tmp/vc.dylib"), on: .any).called(1)
        verify(w.capture).start(device: .value(Self.device), onFrame: .any).called(1)
        #expect(w.session.phase == .streaming(deviceUID: "u-1"))
        #expect(w.session.lastError == nil)
    }

    @Test func `start failure on injection leaves the session idle with an error`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any)
            .willThrow(NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no perm"]
            ))

        await w.session.start(device: Self.device, on: w.sim, dylibPath: "/tmp/vc.dylib")

        verify(w.capture).start(device: .any, onFrame: .any).called(0)
        #expect(w.session.phase == .idle)
        #expect(w.session.lastError?.contains("no perm") == true)
    }

    @Test func `start failure on capture leaves the session idle with an error`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        // Override `start` to throw instead of capturing the closure.
        given(w.capture).start(device: .any, onFrame: .any)
            .willThrow(NSError(
                domain: "test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "device busy"]
            ))

        await w.session.start(device: Self.device, on: w.sim, dylibPath: "/tmp/vc.dylib")

        #expect(w.session.phase == .idle)
        #expect(w.session.lastError?.contains("device busy") == true)
    }

    @Test func `incoming frames are written to the sink with the current flags`() async throws {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.sink).write(.any, flags: .any).willReturn(())
        stubHappyCapture(w)

        w.session.setFlags(CameraFlags(fillGravity: true, mirror: false))
        await w.session.start(device: Self.device, on: w.sim, dylibPath: "/tmp/vc.dylib")

        let frame = try CameraFrame(
            sequence: 1, timestampMs: 100, width: 2, height: 2, pixels: Data(count: 16)
        )
        w.captures.onFrame?(frame)
        await Task.yield()

        verify(w.sink).write(.any, flags: .value(CameraFlags(fillGravity: true, mirror: false)))
            .called(1)
    }

    @Test func `stop drops back to idle and tears down capture`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.capture).stop().willReturn(())
        stubHappyCapture(w)

        await w.session.start(device: Self.device, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await w.session.stop()

        verify(w.capture).stop().called(1)
        #expect(w.session.phase == .idle)
        #expect(w.session.fps == 0)
    }

    @Test func `sampleFPS divides frame delta by elapsed seconds`() async throws {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.sink).write(.any, flags: .any).willReturn(())
        stubHappyCapture(w)

        await w.session.start(device: Self.device, on: w.sim, dylibPath: "/tmp/vc.dylib")
        w.session.sampleFPS()  // seed baseline; fps stays 0

        let frame = try CameraFrame(
            sequence: 1, timestampMs: 0, width: 2, height: 2, pixels: Data(count: 16)
        )
        for _ in 0..<30 { w.captures.onFrame?(frame) }
        await Task.yield()

        // Wait at least 100 ms so the divisor is well-defined.
        try await Task.sleep(nanoseconds: 110_000_000)
        w.session.sampleFPS()

        #expect(w.session.fps > 0)
    }
}
