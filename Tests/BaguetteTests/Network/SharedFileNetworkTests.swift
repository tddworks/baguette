import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `SharedFileNetwork` — publishing a
/// `NetworkCondition` where the injected dylib can read it, and arming /
/// disarming that dylib.
///
/// The file write is real here, into a temp directory, for the same reason
/// `SharedFileMotionTests` does it: it's a one-shot `Data.write`, so a
/// mockable sink would be an abstraction that exists only for the test.
/// Reading the bytes back *is* the state assertion. The one genuine
/// collaborator — injection — is already `@Mockable`.
@Suite("SharedFileNetwork")
struct SharedFileNetworkTests {

    private static let dylib = "/builds/abc123/VirtualNetwork.dylib"

    /// - Parameter armError: when set, arming fails with it. Registered
    ///   instead of the success stub rather than after it — Mockable matches
    ///   the first registration, so a later `willThrow` on the same call
    ///   would be shadowed by an earlier `willReturn`.
    private func makeNetwork(
        dylibPath: String? = SharedFileNetworkTests.dylib,
        armError: (any Error)? = nil
    ) -> (SharedFileNetwork, MockSimulatorInjection, MockSimulator, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("network-\(UUID().uuidString).json")
        let injection = MockSimulatorInjection()
        if let armError {
            given(injection).arm(dylibPath: .any, on: .any).willThrow(armError)
        } else {
            given(injection).arm(dylibPath: .any, on: .any).willReturn(())
        }
        given(injection).disarm(dylibPath: .any, on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let network = SharedFileNetwork(
            fileURL: url, dylibPath: dylibPath, injection: injection)
        return (network, injection, sim, url)
    }

    private let threeG = NetworkProfile.threeG.condition

    @Test func `publishes to a path that names the simulator`() async throws {
        // Every simulator sees the host's `/tmp`, so a single shared file
        // meant conditioning one device replaced what an injected app on
        // another was still reading. Both sides derive this path — the
        // dylib from its own `SIMULATOR_UDID`.
        #expect(SharedFileNetwork.path(forUDID: "ABC-123")
                    == "/tmp/BaguetteNetwork-ABC-123.json")
        #expect(SharedFileNetwork.path(forUDID: "A") != SharedFileNetwork.path(forUDID: "B"))
    }

    @Test func `apply writes the condition where the dylib reads it`() async throws {
        let (network, _, sim, url) = makeNetwork()

        try await network.apply(threeG, on: sim)

        let written = try Data(contentsOf: url)
        #expect(written == (try threeG.encoded()))
        // And it decodes back to the same condition, so the dylib is reading
        // exactly what we meant.
        #expect(try NetworkCondition(decoding: written) == threeG)
    }

    @Test func `apply arms the network dylib`() async throws {
        let (network, injection, sim, _) = makeNetwork()

        try await network.apply(threeG, on: sim)

        verify(injection).arm(dylibPath: .value(Self.dylib), on: .any).called(1)
    }

    @Test func `apply replaces the previous condition rather than appending`() async throws {
        // The file is a single current value, not a log — a dylib reading a
        // concatenation would fail to parse and condition nothing at all,
        // which looks exactly like the feature being off.
        let (network, _, sim, url) = makeNetwork()

        try await network.apply(threeG, on: sim)
        try await network.apply(.offline, on: sim)

        #expect(try NetworkCondition(decoding: try Data(contentsOf: url)) == .offline)
    }

    @Test func `clear stops throttling an app that is already running`() async throws {
        // The whole safety argument for this feature. Disarming only stops
        // *future* launches loading the dylib; an app already running still
        // has it loaded and still reads this file. If clearing left the last
        // condition in place, that app would stay throttled indefinitely —
        // and a forgotten throttle reads as "the app is slow", not as an
        // obvious mistake.
        //
        // Unlike motion — where parking has to preserve the step totals only
        // the session knows, so the caller does it — a network has exactly
        // one sane cleared state, so `clear` guarantees it rather than
        // trusting three call sites to remember.
        let (network, _, sim, url) = makeNetwork()
        try await network.apply(threeG, on: sim)

        try await network.clear(on: sim)

        let left = try NetworkCondition(decoding: try Data(contentsOf: url))
        #expect(left.isUnconditioned)
    }

    @Test func `clear disarms the dylib`() async throws {
        let (network, injection, sim, _) = makeNetwork()
        try await network.apply(threeG, on: sim)

        try await network.clear(on: sim)

        verify(injection).disarm(dylibPath: .value(Self.dylib), on: .any).called(1)
    }

    @Test func `clear leaves a readable file rather than deleting it`() async throws {
        // Deleting would leave a live reader with nothing to read, which the
        // dylib would have to interpret — and "no file" meaning "no
        // conditioning" is a rule that only holds if it's never ambiguous.
        // An explicit unconditioned value says it outright.
        let (network, _, sim, url) = makeNetwork()
        try await network.apply(threeG, on: sim)

        try await network.clear(on: sim)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func `a failed arm surfaces rather than reporting success`() async {
        let failure = SimctlCapture.Failure.failed(udid: "U", status: 2, output: "arm failed")
        let (network, _, sim, _) = makeNetwork(
            armError: failure)

        var threw = false
        do {
            try await network.apply(threeG, on: sim)
        } catch {
            threw = true
            #expect((error as? SimctlCapture.Failure) == failure)
        }
        #expect(threw)
    }

    @Test func `apply reports a missing dylib rather than arming an empty path`() async {
        // A build that didn't ship VirtualNetwork.dylib has nothing to arm.
        // Arming an empty entry makes dyld log a load failure for every app
        // launched afterwards, and publishing a condition nothing reads
        // would look like success while doing nothing at all.
        let (network, injection, sim, _) = makeNetwork(dylibPath: nil)

        var threw = false
        do {
            try await network.apply(threeG, on: sim)
        } catch {
            threw = true
            #expect((error as? NetworkError) == .dylibMissing)
        }
        #expect(threw)
        verify(injection).arm(dylibPath: .any, on: .any).called(0)
    }

    @Test func `current reports the condition this simulator is subject to`() async throws {
        let (network, injection, sim, _) = makeNetwork()
        given(injection).armed(dylibPath: .any, on: .any).willReturn(true)
        try await network.apply(threeG, on: sim)

        #expect(try await network.current(on: sim) == threeG)
    }

    @Test func `current reports nothing for a simulator that is not armed`() async throws {
        // The condition file is one per host, so a second simulator sees the
        // same bytes without being subject to them. Reporting "3g applied"
        // there would be a false alarm, and a badge that cries wolf is a
        // badge people stop reading — which is exactly what this feature
        // cannot afford.
        let (network, injection, sim, _) = makeNetwork()
        given(injection).armed(dylibPath: .any, on: .any).willReturn(false)
        try await network.apply(threeG, on: sim)

        #expect(try await network.current(on: sim) == nil)
    }

    @Test func `current reports nothing when nothing has been published`() async throws {
        let (network, injection, sim, _) = makeNetwork()
        given(injection).armed(dylibPath: .any, on: .any).willReturn(true)

        #expect(try await network.current(on: sim) == nil)
    }

    @Test func `current propagates an unreadable injection state instead of reporting no conditioning`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", stderr: "simulator unavailable", status: 2)
        let network = SharedFileNetwork(
            fileURL: fixture.directory.appendingPathComponent("network.json"),
            dylibPath: Self.dylib, injection: fixture.injection)

        await #expect(throws: SimctlCapture.Failure.failed(udid: "U", status: 2, output: "simulator unavailable")) {
            try await network.current(on: fixture.simulator)
        }
    }

    @Test func `clearing a build with no dylib does nothing rather than failing`() async throws {
        // Nothing was ever armed, so there is nothing to disarm — and a
        // `network clear` that reported failure on such a build would send
        // someone hunting for a problem that isn't there.
        let (network, injection, sim, _) = makeNetwork(dylibPath: nil)

        try await network.clear(on: sim)

        verify(injection).disarm(dylibPath: .any, on: .any).called(0)
    }

    @Test func `applies into a directory that does not exist yet`() async throws {
        // The shared path is configurable, and a caller pointing at a fresh
        // directory shouldn't have to create it first.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("network-dir-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("BaguetteNetwork.json")
        let injection = MockSimulatorInjection()
        given(injection).arm(dylibPath: .any, on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let network = SharedFileNetwork(
            fileURL: url, dylibPath: Self.dylib, injection: injection)

        try await network.apply(threeG, on: sim)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
