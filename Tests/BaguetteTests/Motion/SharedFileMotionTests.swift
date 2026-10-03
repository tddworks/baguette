import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `SharedFileMotion` — publishing a
/// `MotionIntent` where the injected dylib can read it, and arming /
/// disarming that dylib.
///
/// The file write is real here, into a temp directory: it's a one-shot
/// `Data.write`, so inventing a mockable sink for it would be an
/// abstraction that exists only for the test. Reading the bytes back *is*
/// the state assertion. The one genuine collaborator — injection — is
/// already `@Mockable`.
@Suite("SharedFileMotion")
struct SharedFileMotionTests {

    private static let dylib = "/builds/abc123/BaguetteMotion.dylib"

    /// - Parameter armError: when set, arming fails with it. Registered
    ///   instead of the success stub rather than after it — Mockable matches
    ///   the first registration, so a later `willThrow` on the same call
    ///   would be shadowed by an earlier `willReturn`.
    private func makeMotion(
        armError: (any Error)? = nil
    ) -> (SharedFileMotion, MockSimulatorInjection, MockSimulator, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motion-\(UUID().uuidString).json")
        let injection = MockSimulatorInjection()
        if let armError {
            given(injection).arm(dylibPath: .any, on: .any).willThrow(armError)
        } else {
            given(injection).arm(dylibPath: .any, on: .any).willReturn(())
        }
        given(injection).disarm(dylibPath: .any, on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let motion = SharedFileMotion(fileURL: url, dylibPath: Self.dylib, injection: injection)
        return (motion, injection, sim, url)
    }

    private func walking(speed: Double = 1.5, startedAt: Double = 1000) -> MotionIntent {
        MotionIntent(kind: .walking, confidence: .high, speed: speed,
                     startedAt: startedAt, stepsBefore: 0, distanceBefore: 0)
    }

    @Test func `scopes the intent file to one simulator`() async throws {
        // One shared path meant publishing for simulator B replaced the
        // intent an injected app on simulator A was still reading. The dylib
        // builds the same path from its own SIMULATOR_UDID.
        let a = SharedFileMotion.path(forUDID: "AAAA-1111")
        let b = SharedFileMotion.path(forUDID: "BBBB-2222")
        #expect(a != b)
        #expect(a.hasSuffix("BaguetteMotion-AAAA-1111.json"))
    }

    @Test func `reads back the intent it published`() async throws {
        // The published file *is* the state for callers that keep none —
        // the CLI recovers the pedometer's running totals from it.
        let (motion, _, sim, _) = makeMotion()
        #expect(motion.published() == nil)

        let intent = walking()
        try await motion.publish(intent, on: sim)

        #expect(motion.published() == intent)
    }

    @Test func `publish writes the intent where the dylib reads it`() async throws {
        let (motion, _, sim, url) = makeMotion()
        let intent = walking()

        try await motion.publish(intent, on: sim)

        let written = try Data(contentsOf: url)
        #expect(written == (try intent.encoded()))
        // And it decodes back to the same intent, so the dylib is reading
        // exactly what we meant.
        #expect(try MotionIntent(decoding: written) == intent)
    }

    @Test func `publish arms the motion dylib`() async throws {
        let (motion, injection, sim, _) = makeMotion()

        try await motion.publish(walking(), on: sim)

        verify(injection).arm(dylibPath: .value(Self.dylib), on: .any).called(1)
    }

    @Test func `publish replaces the previous intent rather than appending`() async throws {
        // The file is a single current value, not a log — a dylib reading a
        // concatenation would fail to parse and see no motion at all.
        let (motion, _, sim, url) = makeMotion()

        try await motion.publish(walking(speed: 1.5), on: sim)
        let second = MotionIntent(kind: .running, confidence: .high, speed: 3.6,
                                  startedAt: 2000, stepsBefore: 21, distanceBefore: 15.75)
        try await motion.publish(second, on: sim)

        #expect(try MotionIntent(decoding: try Data(contentsOf: url)) == second)
    }

    @Test func `clear disarms without destroying the last published intent`() async throws {
        // Disarming only stops *future* app launches loading the dylib. An
        // app already running still has it loaded and still reads the file,
        // so the file must survive — the session parks the device as
        // stationary first, and that's what a running app keeps seeing.
        // Deleting it would leave a live reader with nothing to read.
        let (motion, injection, sim, url) = makeMotion()
        let parked = MotionIntent.stationary(startedAt: 3000, stepsBefore: 812,
                                            distanceBefore: 610)
        try await motion.publish(parked, on: sim)

        try await motion.clear(on: sim)

        verify(injection).disarm(dylibPath: .value(Self.dylib), on: .any).called(1)
        #expect(try MotionIntent(decoding: try Data(contentsOf: url)) == parked)
    }

    @Test func `a failed arm surfaces rather than reporting success`() async {
        let (motion, _, sim, _) = makeMotion(
            armError: SimctlCapture.Failure.failed(udid: "U", status: 2, output: ""))

        var threw = false
        do {
            try await motion.publish(walking(), on: sim)
        } catch {
            threw = true
            #expect((error as? SimctlCapture.Failure) == .failed(udid: "U", status: 2, output: ""))
        }
        #expect(threw)
    }

    @Test func `publish reports a missing dylib rather than arming an empty path`() async {
        // A build that didn't ship VirtualMotion.dylib has nothing to arm.
        // Arming an empty entry would make dyld log a load failure for every
        // app launched afterwards, and publishing an intent nothing reads
        // would look like success while doing nothing at all.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motion-\(UUID().uuidString).json")
        let injection = MockSimulatorInjection()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let motion = SharedFileMotion(fileURL: url, dylibPath: nil, injection: injection)

        var threw = false
        do {
            try await motion.publish(walking(), on: sim)
        } catch {
            threw = true
            #expect((error as? MotionError) == .dylibMissing)
        }
        #expect(threw)
        verify(injection).arm(dylibPath: .any, on: .any).called(0)
    }

    @Test func `publishes into a directory that does not exist yet`() async throws {
        // The shared path is configurable, and a caller pointing at a fresh
        // directory shouldn't have to create it first.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motion-dir-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("BaguetteMotion.json")
        let injection = MockSimulatorInjection()
        given(injection).arm(dylibPath: .any, on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let motion = SharedFileMotion(fileURL: url, dylibPath: Self.dylib, injection: injection)

        try await motion.publish(walking(), on: sim)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
