import Foundation
import Mockable
import Testing

@testable import Baguette

/// Behaviour spec for the CameraSession state machine. The session
/// owns three collaborators (capture, sink, injection). Tests inject
/// the auto-generated `MockXxx` and assert on returned state.
@Suite("CameraSession")
@MainActor
struct CameraSessionTests {

    private static let webcam = CameraSource.device(uid: "u-1")

    /// Captures `start(source:onFrame:)` callbacks so the test can
    /// fire frames through the orchestrator on demand.
    final class Captures: @unchecked Sendable {
        var onFrame: (@Sendable (CameraFrame) -> Void)?
    }

    private struct Wiring {
        let session: CameraSession
        let webcam: MockCameraCapture
        let image: MockCameraCapture
        let video: MockCameraCapture
        let sink: MockCameraFrameSink
        let injection: MockSimulatorInjection
        let sim: MockSimulator
        let captures: Captures
    }

    /// Bare wiring — mocks are created but NOT pre-stubbed. Each test
    /// configures only the behaviours it needs so overrides don't
    /// collide with FIFO matching.
    private func makeWiring(
        decorate: (MockSimulatorInjection) -> any SimulatorInjection = { $0 },
        guestTerminated: @escaping (String) throws -> Bool = { _ in false }
    ) -> Wiring {
        let webcam = MockCameraCapture()
        let image = MockCameraCapture()
        let video = MockCameraCapture()
        let sink = MockCameraFrameSink()
        let injection = MockSimulatorInjection()
        let sim = MockSimulator()
        given(sim).udid.willReturn("sim-U")
        let captures = Captures()
        let session = CameraSession(
            webcam: webcam, image: image, video: video,
            sink: sink, injection: decorate(injection), guestTerminated: guestTerminated
        )
        return Wiring(
            session: session, webcam: webcam, image: image, video: video,
            sink: sink, injection: injection, sim: sim, captures: captures
        )
    }

    /// Helper for happy-path stubs — call from each test that wants
    /// the webcam capture to succeed and record the onFrame callback.
    private func stubHappyCapture(_ w: Wiring) {
        given(w.webcam).start(source: .any, onFrame: .any).willProduce { _, onFrame in
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

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")

        verify(w.injection).arm(dylibPath: .value("/tmp/vc.dylib"), on: .any).called(1)
        verify(w.webcam).start(source: .value(Self.webcam), onFrame: .any).called(1)
        #expect(w.session.phase == .streaming(source: Self.webcam))
        #expect(w.session.lastError == nil)
    }

    @Test func `an image source is routed to the image capture, not the webcam or video`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.image).start(source: .any, onFrame: .any).willReturn(())

        let source = CameraSource.image(path: "/tmp/pic.png")
        await w.session.start(source: source, on: w.sim, dylibPath: "/tmp/vc.dylib")

        verify(w.image).start(source: .value(source), onFrame: .any).called(1)
        verify(w.webcam).start(source: .any, onFrame: .any).called(0)
        verify(w.video).start(source: .any, onFrame: .any).called(0)
        #expect(w.session.phase == .streaming(source: source))
    }

    @Test func `stop tears down the capture that was started for the active source`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.video).start(source: .any, onFrame: .any).willReturn(())
        given(w.video).stop().willReturn(())

        await w.session.start(source: .video(path: "/tmp/clip.mp4"), on: w.sim, dylibPath: "/tmp/vc.dylib")
        await w.session.stop()

        verify(w.video).stop().called(1)
        verify(w.webcam).stop().called(0)
        #expect(w.session.phase == .idle)
    }

    @Test func `start failure on injection leaves the session idle with an error`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no perm"]
                ))

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")

        verify(w.webcam).start(source: .any, onFrame: .any).called(0)
        #expect(w.session.phase == .idle)
        #expect(w.session.lastError?.contains("no perm") == true)
    }

    @Test func `start failure on capture leaves the session idle with an error`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        // Override `start` to throw instead of capturing the closure.
        given(w.webcam).start(source: .any, onFrame: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "device busy"]
                ))

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")

        #expect(w.session.phase == .idle)
        #expect(w.session.lastError?.contains("device busy") == true)
    }

    @Test func `incoming frames are written to the sink with the current flags`() async throws {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.sink).write(.any, flags: .any).willReturn(())
        stubHappyCapture(w)

        w.session.setFlags(CameraFlags(fillGravity: true, mirror: false))
        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")

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
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await w.session.stop()

        verify(w.webcam).stop().called(1)
        #expect(w.session.phase == .idle)
        #expect(w.session.fps == 0)
    }

    @Test func `stop disarms the dylib on the simulator it armed`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await w.session.stop()

        // Injection must be removed on teardown — leaving DYLD_INSERT_LIBRARIES
        // armed loads the dylib into every future app launch until reboot.
        // It names *its own* dylib: the variable is shared with other
        // injecting features, so a blanket teardown would disarm theirs too.
        verify(w.injection).disarm(dylibPath: .value("/tmp/vc.dylib"), on: .any).called(1)
    }

    @Test func `a failed disarm stays visible and a later explicit stop retries it`() async throws {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "disarm denied"]))
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await w.session.stop()

        #expect(w.session.phase == .idle)
        #expect(w.session.cleanupRequired)
        #expect(w.session.lastError?.contains("disarm denied") == true)
        let state = try #require(
            JSONSerialization.jsonObject(with: Data(Server.cameraStateJSON(w.session, requestId: "stop-1").utf8))
                as? [String: Any])
        #expect(state["ok"] as? Bool == false)
        #expect(state["cleanupRequired"] as? Bool == true)
        #expect(state["requestId"] as? String == "stop-1")

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/new.dylib")
        verify(w.injection).arm(dylibPath: .any, on: .any).called(1)
        #expect(w.session.cleanupRequired)
        await w.session.stop()
        #expect(!w.session.cleanupRequired)
        #expect(w.session.lastError == nil)
        verify(w.injection).disarm(dylibPath: .value("/tmp/vc.dylib"), on: .any).called(2)
        verify(w.webcam).stop().called(1)
    }

    @Test func `unsolicited camera state has no request id and parse errors retain their request`() throws {
        let w = makeWiring()
        let heartbeat = try #require(
            JSONSerialization.jsonObject(with: Data(Server.cameraStateJSON(w.session).utf8)) as? [String: Any])
        #expect(heartbeat["requestId"] == nil)
        let failure = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    Server.cameraStateJSON(
                        w.session, requestId: "bad-command", error: "missing camera"
                    ).utf8)) as? [String: Any])
        #expect(failure["requestId"] as? String == "bad-command")
        #expect(failure["ok"] as? Bool == false)
        #expect(failure["error"] as? String == "missing camera")
        #expect(failure["cleanupRequired"] as? Bool == false)
    }

    @Test func `capture failure preserves both errors when disarming also fails`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "disarm denied"]))
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).start(source: .any, onFrame: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "device busy"]))

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        #expect(w.session.cleanupRequired)
        #expect(w.session.lastError?.contains("device busy") == true)
        #expect(w.session.lastError?.contains("disarm denied") == true)
        await w.session.stop()
        #expect(!w.session.cleanupRequired)
        #expect(w.session.lastError == nil)
    }

    @Test func `concurrent stop waits for the shared disarm result`() async {
        @MainActor final class Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var secondEntered = false
            var secondFinished = false
        }
        // Mockable's producers are synchronous even for async methods.
        @MainActor final class DelayedInjection: SimulatorInjection {
            let wrapped: MockSimulatorInjection
            let gate: Gate
            init(_ wrapped: MockSimulatorInjection, gate: Gate) {
                self.wrapped = wrapped
                self.gate = gate
            }
            func arm(dylibPath: String, on simulator: any Simulator) async throws {
                try await wrapped.arm(dylibPath: dylibPath, on: simulator)
            }
            func disarm(dylibPath: String, on simulator: any Simulator) async throws {
                await withCheckedContinuation { gate.continuation = $0 }
                try await wrapped.disarm(dylibPath: dylibPath, on: simulator)
            }
            func armed(dylibPath: String, on simulator: any Simulator) async throws -> Bool {
                try await wrapped.armed(dylibPath: dylibPath, on: simulator)
            }
        }
        let gate = Gate()
        let w = makeWiring(decorate: { DelayedInjection($0, gate: gate) })
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)
        given(w.injection).disarm(dylibPath: .any, on: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "disarm denied"]))
        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        let first = Task { await w.session.stop() }
        while gate.continuation == nil { await Task.yield() }
        let second = Task {
            gate.secondEntered = true
            await w.session.stop()
            gate.secondFinished = true
        }
        while !gate.secondEntered { await Task.yield() }
        #expect(!gate.secondFinished)
        gate.continuation?.resume()
        await first.value
        await second.value
        #expect(w.session.cleanupRequired)
        #expect(w.session.lastError?.contains("disarm denied") == true)
        verify(w.injection).disarm(dylibPath: .any, on: .any).called(1)
    }

    @Test func `the server admits one camera connection until its cleanup completes`() async throws {
        let sessions = CameraSessions(guestTerminated: { _ in false })
        let first = makeWiring()
        let second = makeWiring()
        let connected = try sessions.connect(udid: "U") { first.session }
        #expect(throws: (any Error).self) { try sessions.connect(udid: "U") { second.session } }
        #expect(throws: (any Error).self) { try sessions.connect(udid: "V") { second.session } }
        await sessions.disconnect(connected)
        #expect(try sessions.connect(udid: "V") { second.session } === second.session)
    }

    @Test func `failed cleanup survives disconnect and only its device can recover it`() async throws {
        let sessions = CameraSessions(guestTerminated: { _ in false })
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any)
            .willThrow(
                NSError(
                    domain: "test", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "disarm denied"]))
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)
        let connected = try sessions.connect(udid: "U") { w.session }
        await connected.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await connected.stop()
        await sessions.disconnect(connected)
        verify(w.injection).disarm(dylibPath: .any, on: .any).called(1)

        let other = makeWiring()
        #expect(throws: (any Error).self) { try sessions.connect(udid: "V") { other.session } }
        let recovered = try sessions.connect(udid: "U") { other.session }
        #expect(recovered === connected)
        #expect(recovered.cleanupRequired)
        await recovered.stop()
        #expect(!recovered.cleanupRequired)
        await sessions.disconnect(recovered)
        #expect(try sessions.connect(udid: "V") { other.session } === other.session)
    }

    @Test func `a disconnected camera owner is released only after guest termination is confirmed`() async throws {
        for terminated in [true, false] {
            let sessions = CameraSessions(guestTerminated: { _ in terminated })
            let w = makeWiring()
            given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
            given(w.injection).disarm(dylibPath: .any, on: .any)
                .willThrow(NSError(domain: "disarm", code: 1))
            given(w.webcam).stop().willReturn(())
            stubHappyCapture(w)
            let session = try sessions.connect(udid: "U") { w.session }
            await session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
            // Even confirmed shutdown does not let another socket steal a live connection.
            #expect(throws: CameraOwnershipError.self) { try sessions.connect(udid: "V") { makeWiring().session } }
            await session.stop()
            await sessions.disconnect(session)
            #expect(session.cleanupRequired)
            let other = makeWiring()
            if terminated {
                #expect(try sessions.connect(udid: "V") { other.session } === other.session)
            } else {
                #expect(throws: CameraOwnershipError.self) { try sessions.connect(udid: "V") { other.session } }
            }
            verify(w.injection).disarm(dylibPath: .any, on: .any).called(1)
        }
    }

    @Test func `failed guest-state confirmation keeps the disconnected camera owner`() async throws {
        let sessions = CameraSessions(guestTerminated: { _ in throw NSError(domain: "device list unavailable", code: 1)
        })
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any)
            .willThrow(NSError(domain: "disarm", code: 1))
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)
        let session = try sessions.connect(udid: "U") { w.session }
        await session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await sessions.disconnect(session)
        #expect(throws: (any Error).self) { try sessions.connect(udid: "V") { makeWiring().session } }
        #expect(session.cleanupRequired)
        #expect(try sessions.connect(udid: "U") { makeWiring().session } === session)
        verify(w.injection).disarm(dylibPath: .any, on: .any).called(1)
    }

    @Test func `explicit stop confirms cleanup when the armed guest has terminated`() async {
        for terminated in [true, false] {
            let w = makeWiring(guestTerminated: { _ in terminated })
            given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
            given(w.injection).disarm(dylibPath: .any, on: .any)
                .willThrow(NSError(domain: "disarm", code: 1))
            given(w.webcam).stop().willReturn(())
            stubHappyCapture(w)
            await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
            await w.session.stop()
            #expect(w.session.cleanupRequired == !terminated)
            #expect((w.session.lastError == nil) == terminated)
            #expect(w.session.phase == .idle)
            verify(w.webcam).stop().called(1)
        }
    }

    @Test func `explicit stop preserves disarm and state-query failures together`() async {
        let w = makeWiring(guestTerminated: { _ in
            throw NSError(domain: "state", code: 2, userInfo: [NSLocalizedDescriptionKey: "device list unavailable"])
        })
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any)
            .willThrow(NSError(domain: "disarm", code: 1, userInfo: [NSLocalizedDescriptionKey: "disarm denied"]))
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)
        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        await w.session.stop()
        #expect(w.session.cleanupRequired)
        #expect(w.session.lastError?.contains("disarm denied") == true)
        #expect(w.session.lastError?.contains("device list unavailable") == true)
    }

    @Test func `a fresh session stop must disarm the selected guest and retain a failed cleanup for retry`() async {
        let w = makeWiring()
        given(w.injection).disarm(dylibPath: .value("/tmp/current/VirtualCamera.dylib"), on: .any)
            .willThrow(NSError(domain: "disarm", code: 1, userInfo: [NSLocalizedDescriptionKey: "disarm denied"]))
        given(w.injection).disarm(dylibPath: .value("/tmp/current/VirtualCamera.dylib"), on: .any).willReturn(())
        await w.session.stop(on: w.sim, dylibPath: "/tmp/current/VirtualCamera.dylib")
        #expect(w.session.cleanupRequired)
        #expect(w.session.lastError?.contains("disarm denied") == true)
        await w.session.stop(on: w.sim, dylibPath: "/tmp/current/VirtualCamera.dylib")
        #expect(!w.session.cleanupRequired)
        #expect(w.session.lastError == nil)
        verify(w.injection).disarm(dylibPath: .any, on: .any).called(2)
    }

    @Test func `a fresh session stop confirms either disarm or verified guest termination`() async {
        for terminated in [false, true] {
            let w = makeWiring(guestTerminated: { udid in
                #expect(udid == "sim-U")
                return terminated
            })
            given(w.injection).disarm(dylibPath: .value("/tmp/current/VirtualCamera.dylib"), on: .any)
                .willProduce { _, simulator in
                    #expect(simulator.udid == "sim-U")
                    if terminated { throw NSError(domain: "guest gone", code: 1) }
                }
            await w.session.stop(on: w.sim, dylibPath: "/tmp/current/VirtualCamera.dylib")
            #expect(!w.session.cleanupRequired)
            #expect(w.session.lastError == nil)
            verify(w.injection).disarm(dylibPath: .any, on: .any).called(1)
        }
    }

    /// `stop` suspends twice (tearing down capture, then disarming the
    /// dylib). Being `@MainActor` serialises those steps but doesn't stop
    /// a second `stop` from interleaving at a suspension point — and if
    /// the phase is still `.streaming` when it looks, it tears the same
    /// session down a second time.
    @Test func `a stop that lands mid-teardown doesn't tear down twice`() async {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.injection).disarm(dylibPath: .any, on: .any).willReturn(())
        given(w.webcam).stop().willReturn(())
        stubHappyCapture(w)

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
        async let first: Void = w.session.stop()
        async let second: Void = w.session.stop()
        _ = await (first, second)

        verify(w.webcam).stop().called(1)
        verify(w.injection).disarm(dylibPath: .any, on: .any).called(1)
        #expect(w.session.phase == .idle)
    }

    @Test func `sampleFPS divides frame delta by elapsed seconds`() async throws {
        let w = makeWiring()
        given(w.injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(w.sink).write(.any, flags: .any).willReturn(())
        stubHappyCapture(w)

        await w.session.start(source: Self.webcam, on: w.sim, dylibPath: "/tmp/vc.dylib")
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
