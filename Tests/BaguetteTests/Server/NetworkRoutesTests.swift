import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the network routes.
///
/// Same shape as the location and motion routes: the pure parse + dispatch
/// helpers are driven with `MockSimulators` + `MockNetwork`, not the
/// Hummingbird `Response` wrappers.
@Suite("Server network routes")
@MainActor
struct NetworkRoutesTests {

    private struct Wiring {
        let simulators: MockSimulators
        let sim: MockSimulator
        let network: MockNetwork
        let captures: Captures
    }

    private final class Captures: @unchecked Sendable {
        var applied: [NetworkCondition] = []
        var last: NetworkCondition? { applied.last }
    }

    private func makeWiring(
        current: NetworkCondition? = nil,
        applyError: (any Error)? = nil
    ) -> Wiring {
        let simulators = MockSimulators()
        let sim = MockSimulator()
        let network = MockNetwork()
        let captures = Captures()
        given(simulators).find(udid: .any).willReturn(sim)
        given(sim).udid.willReturn("U")
        given(sim).name.willReturn("iPhone 17 Pro")
        given(sim).network().willReturn(network)
        if let applyError {
            given(network).apply(.any, on: .any).willThrow(applyError)
        } else {
            given(network).apply(.any, on: .any).willProduce { condition, _ in
                captures.applied.append(condition)
            }
        }
        given(network).clear(on: .any).willReturn(())
        given(network).current(on: .any).willReturn(current)
        return Wiring(simulators: simulators, sim: sim, network: network, captures: captures)
    }

    // MARK: - parse

    @Test func `parseNetworkRequest resolves a named preset`() {
        // The browser posts the preset's *name* and Swift resolves the
        // numbers, so NLC's figures live in exactly one place rather than
        // being copied into JavaScript where the two would drift.
        #expect(Server.parseNetworkRequest(json: #"{"profile":"3g"}"#)
                    == NetworkProfile.threeG.condition)
    }

    @Test func `parseNetworkRequest reads explicit numbers`() {
        let condition = Server.parseNetworkRequest(
            json: #"{"latencyMs":300,"bandwidthKbps":400,"lossPercent":5}"#)
        #expect(condition?.latencyMs == 300)
        #expect(condition?.bandwidthKbps == 400)
        #expect(condition?.lossPercent == 5)
    }

    @Test func `parseNetworkRequest leaves an unnamed bandwidth unmetered`() {
        #expect(Server.parseNetworkRequest(json: #"{"latencyMs":300}"#)?.bandwidthKbps == nil)
    }

    @Test func `parseNetworkRequest reads offline`() {
        #expect(Server.parseNetworkRequest(json: #"{"offline":true}"#) == .offline)
    }

    @Test func `parseNetworkRequest refuses to mix a preset with anything else`() {
        // Same rule the CLI holds: one source of truth per request, so
        // nobody has to remember whether the preset or the field wins.
        #expect(Server.parseNetworkRequest(json: #"{"profile":"3g","lossPercent":20}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"profile":"3g","offline":true}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"offline":true,"latencyMs":300}"#) == nil)
    }

    @Test func `parseNetworkRequest rejects a body that conditions nothing`() {
        #expect(Server.parseNetworkRequest(json: "{}") == nil)
        #expect(Server.parseNetworkRequest(json: "not json") == nil)
    }

    @Test func `parseNetworkRequest rejects numbers that describe no network`() {
        #expect(Server.parseNetworkRequest(json: #"{"latencyMs":-1}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"lossPercent":150}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"bandwidthKbps":0}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"profile":"2g"}"#) == nil)
    }

    @Test func `parseNetworkRequest ignores an offline flag that is false`() {
        // The browser card posts its whole form, so `offline:false` arrives
        // alongside real numbers on every ordinary request. Treating it as
        // a source would make every such body a conflict.
        let condition = Server.parseNetworkRequest(
            json: #"{"offline":false,"latencyMs":300}"#)
        #expect(condition?.latencyMs == 300)
        #expect(condition?.isOffline == false)
    }

    // MARK: - apply

    @Test func `applyNetwork conditions the simulator`() async {
        let w = makeWiring()

        let outcome = await Server.applyNetwork(
            udid: "U", body: #"{"profile":"edge"}"#, simulators: w.simulators)

        #expect(outcome == .ok)
        #expect(w.captures.last == NetworkProfile.edge.condition)
    }

    @Test func `applyNetwork reports an unknown device`() async {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)

        let outcome = await Server.applyNetwork(
            udid: "nope", body: #"{"profile":"edge"}"#, simulators: simulators)

        #expect(outcome == .unknownDevice)
    }

    @Test func `applyNetwork reports a malformed body`() async {
        let w = makeWiring()
        let outcome = await Server.applyNetwork(
            udid: "U", body: "not json", simulators: w.simulators)
        #expect(outcome == .invalidBody)
    }

    @Test func `applyNetwork surfaces a build with no dylib`() async {
        // Nothing would read the published condition, so reporting success
        // would leave someone testing against a throttle that was never
        // applied.
        let w = makeWiring(applyError: NetworkError.dylibMissing)

        let outcome = await Server.applyNetwork(
            udid: "U", body: #"{"profile":"edge"}"#, simulators: w.simulators)

        #expect(outcome == .dispatchFailed)
    }

    // MARK: - clear

    @Test func `clearNetwork stops conditioning`() async {
        let w = makeWiring()

        let outcome = await Server.clearNetwork(udid: "U", simulators: w.simulators)

        #expect(outcome == .ok)
        verify(w.network).clear(on: .any).called(1)
    }

    @Test func `clearNetwork reports an unknown device`() async {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        #expect(await Server.clearNetwork(udid: "nope", simulators: simulators)
                    == .unknownDevice)
    }

    // MARK: - read-back

    @Test func `networkStateJSON reports what the simulator is subject to`() async throws {
        let w = makeWiring(current: NetworkProfile.threeG.condition)

        let json = try await Server.networkStateJSON(udid: "U", simulators: w.simulators) ?? ""

        #expect(json.contains(#""active":true"#))
        #expect(json.contains(#""latencyMs":200"#))
        #expect(json.contains(#""bandwidthKbps":780"#))
        #expect(json.contains(#""summary":"200 ms latency, 780 kbps""#))
    }

    @Test func `networkStateJSON names the preset when one matches`() async throws {
        // So the card can keep the pill the user pressed lit. It posts a
        // name and gets numbers back; without this it would have to hold
        // NLC's figures itself to recognise them, which is the duplication
        // the whole design avoids.
        let w = makeWiring(current: NetworkProfile.threeG.condition)

        let json = try await Server.networkStateJSON(udid: "U", simulators: w.simulators) ?? ""

        #expect(json.contains(#""profile":"3g""#))
    }

    @Test func `networkStateJSON names no preset for a hand-tuned condition`() async throws {
        let w = makeWiring(
            current: NetworkCondition(latencyMs: 317, bandwidthKbps: 411, lossPercent: 3)!)

        let json = try await Server.networkStateJSON(udid: "U", simulators: w.simulators) ?? ""

        #expect(json.contains(#""profile":null"#))
    }

    @Test func `networkStateJSON reports an unconditioned simulator as inactive`() async throws {
        let w = makeWiring(current: nil)

        let json = try await Server.networkStateJSON(udid: "U", simulators: w.simulators) ?? ""

        #expect(json.contains(#""active":false"#))
    }

    @Test func `networkStateJSON names every preset so the card lists them`() async throws {
        // The browser offers the presets by name and posts the name back.
        // Serving the list means adding a preset appears in the UI without
        // a second edit, and the figures behind each name stay in Swift.
        let w = makeWiring(current: nil)

        let json = try await Server.networkStateJSON(udid: "U", simulators: w.simulators) ?? ""

        for profile in NetworkProfile.allCases {
            #expect(json.contains("\"\(profile.rawValue)\""), "\(profile.rawValue) missing")
        }
    }

    @Test func `networkStateJSON refuses an unknown device rather than calling it unthrottled`() async throws {
        // "This device has no conditioning" and "there is no such device"
        // are different answers, and the first one reads as reassurance.
        // The route turns this nil into a 404, matching motion's read-back.
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)

        #expect(try await Server.networkStateJSON(udid: "nope", simulators: simulators) == nil)
    }

    @Test func `networkStateJSON propagates a failed injection query instead of reporting inactive`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", stderr: "simulator unavailable", status: 2)
        let network = SharedFileNetwork(
            fileURL: fixture.directory.appendingPathComponent("network.json"),
            dylibPath: "/builds/current/VirtualNetwork.dylib", injection: fixture.injection)
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(fixture.simulator)
        given(fixture.simulator).network().willReturn(network)

        await #expect(throws: SimctlCapture.Failure.failed(udid: "U", status: 2, output: "simulator unavailable")) {
            try await Server.networkStateJSON(udid: "U", simulators: simulators)
        }
    }
}
