import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the network routes.
///
/// Same shape as the location and motion routes: the pure parse + dispatch
/// helpers are driven with one device's `MockNetwork`, not the
/// Hummingbird `Response` wrappers.
@Suite("Server network routes")
@MainActor
struct NetworkRoutesTests {

    private struct Wiring {
        let devices: any Devices
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
        let network = MockNetwork()
        let captures = Captures()
        let devices = routeDevices(name: "iPhone 17 Pro") { $0.register(.network) { network } }
        if let applyError {
            given(network).apply(.any).willThrow(applyError)
        } else {
            given(network).apply(.any).willProduce { condition in
                captures.applied.append(condition)
            }
        }
        given(network).clear().willReturn(())
        given(network).current().willReturn(current)
        return Wiring(devices: devices, network: network, captures: captures)
    }

    // MARK: - parse

    @Test func `should resolve a named network preset to its figures`() {
        // The browser posts the preset's *name* and Swift resolves the
        // numbers, so NLC's figures live in exactly one place rather than
        // being copied into JavaScript where the two would drift.
        #expect(Server.parseNetworkRequest(json: #"{"profile":"3g"}"#)
                    == NetworkProfile.threeG.condition)
    }

    @Test func `should read explicit latency, bandwidth and loss figures`() {
        let condition = Server.parseNetworkRequest(
            json: #"{"latencyMs":300,"bandwidthKbps":400,"lossPercent":5}"#)
        #expect(condition?.latencyMs == 300)
        #expect(condition?.bandwidthKbps == 400)
        #expect(condition?.lossPercent == 5)
    }

    @Test func `should leave bandwidth unmetered when the body names none`() {
        #expect(Server.parseNetworkRequest(json: #"{"latencyMs":300}"#)?.bandwidthKbps == nil)
    }

    @Test func `should read an offline network request`() {
        #expect(Server.parseNetworkRequest(json: #"{"offline":true}"#) == .offline)
    }

    @Test func `should refuse a network request that mixes a preset or offline with anything else`() {
        // Same rule the CLI holds: one source of truth per request, so
        // nobody has to remember whether the preset or the field wins.
        #expect(Server.parseNetworkRequest(json: #"{"profile":"3g","lossPercent":20}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"profile":"3g","offline":true}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"offline":true,"latencyMs":300}"#) == nil)
    }

    @Test func `should reject a network body that conditions nothing`() {
        #expect(Server.parseNetworkRequest(json: "{}") == nil)
        #expect(Server.parseNetworkRequest(json: "not json") == nil)
    }

    @Test func `should reject figures or a preset that describe no network`() {
        #expect(Server.parseNetworkRequest(json: #"{"latencyMs":-1}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"lossPercent":150}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"bandwidthKbps":0}"#) == nil)
        #expect(Server.parseNetworkRequest(json: #"{"profile":"2g"}"#) == nil)
    }

    @Test func `should ignore an offline flag that is false`() {
        // The browser card posts its whole form, so `offline:false` arrives
        // alongside real numbers on every ordinary request. Treating it as
        // a source would make every such body a conflict.
        let condition = Server.parseNetworkRequest(
            json: #"{"offline":false,"latencyMs":300}"#)
        #expect(condition?.latencyMs == 300)
        #expect(condition?.isOffline == false)
    }

    // MARK: - apply

    @Test func `should condition the simulator's network with the posted preset`() async {
        let w = makeWiring()

        let outcome = await Server.applyNetwork(
            udid: "U", body: #"{"profile":"edge"}"#, devices: w.devices)

        #expect(outcome == .ok)
        #expect(w.captures.last == NetworkProfile.edge.condition)
    }

    @Test func `should report an unknown device when conditioning its network`() async {
        let devices = routeDevices()

        let outcome = await Server.applyNetwork(
            udid: "nope", body: #"{"profile":"edge"}"#, devices: devices)

        #expect(outcome == .unknownDevice)
    }

    @Test func `should report an invalid body when the network request is malformed`() async {
        let w = makeWiring()
        let outcome = await Server.applyNetwork(
            udid: "U", body: "not json", devices: w.devices)
        #expect(outcome == .invalidBody)
    }

    @Test func `should report a failed dispatch when the build has no network dylib`() async {
        // Nothing would read the published condition, so reporting success
        // would leave someone testing against a throttle that was never
        // applied.
        let w = makeWiring(applyError: NetworkError.dylibMissing)

        let outcome = await Server.applyNetwork(
            udid: "U", body: #"{"profile":"edge"}"#, devices: w.devices)

        #expect(outcome == .dispatchFailed)
    }

    // MARK: - clear

    @Test func `should stop conditioning the simulator's network`() async {
        let w = makeWiring()

        let outcome = await Server.clearNetwork(udid: "U", devices: w.devices)

        #expect(outcome == .ok)
        verify(w.network).clear().called(1)
    }

    @Test func `should report an unknown device when clearing its network conditioning`() async {
        let devices = routeDevices()
        #expect(await Server.clearNetwork(udid: "nope", devices: devices)
                    == .unknownDevice)
    }

    // MARK: - read-back

    @Test func `should report the network condition the simulator is subject to`() async throws {
        let w = makeWiring(current: NetworkProfile.threeG.condition)

        let json = try await Server.networkStateJSON(udid: "U", devices: w.devices) ?? ""

        #expect(json.contains(#""active":true"#))
        #expect(json.contains(#""latencyMs":200"#))
        #expect(json.contains(#""bandwidthKbps":780"#))
        #expect(json.contains(#""summary":"200 ms latency, 780 kbps""#))
    }

    @Test func `should name the preset when the current condition matches one`() async throws {
        // So the card can keep the pill the user pressed lit. It posts a
        // name and gets numbers back; without this it would have to hold
        // NLC's figures itself to recognise them, which is the duplication
        // the whole design avoids.
        let w = makeWiring(current: NetworkProfile.threeG.condition)

        let json = try await Server.networkStateJSON(udid: "U", devices: w.devices) ?? ""

        #expect(json.contains(#""profile":"3g""#))
    }

    @Test func `should name no preset for a hand-tuned network condition`() async throws {
        let w = makeWiring(
            current: NetworkCondition(latencyMs: 317, bandwidthKbps: 411, lossPercent: 3)!)

        let json = try await Server.networkStateJSON(udid: "U", devices: w.devices) ?? ""

        #expect(json.contains(#""profile":null"#))
    }

    @Test func `should report an unconditioned simulator as inactive`() async throws {
        let w = makeWiring(current: nil)

        let json = try await Server.networkStateJSON(udid: "U", devices: w.devices) ?? ""

        #expect(json.contains(#""active":false"#))
    }

    @Test func `should list every network preset so the card can offer them`() async throws {
        // The browser offers the presets by name and posts the name back.
        // Serving the list means adding a preset appears in the UI without
        // a second edit, and the figures behind each name stay in Swift.
        let w = makeWiring(current: nil)

        let json = try await Server.networkStateJSON(udid: "U", devices: w.devices) ?? ""

        for profile in NetworkProfile.allCases {
            #expect(json.contains("\"\(profile.rawValue)\""), "\(profile.rawValue) missing")
        }
    }

    @Test func `should find no network state for an unknown device rather than call it unthrottled`() async throws {
        // "This device has no conditioning" and "there is no such device"
        // are different answers, and the first one reads as reassurance.
        // The route turns this nil into a 404, matching motion's read-back.
        let devices = routeDevices()

        #expect(try await Server.networkStateJSON(udid: "nope", devices: devices) == nil)
    }

    @Test func `should fail rather than report inactive when the injection query fails`() async throws {
        let fixture = try SimulatorInjectionFixture()
        defer { fixture.remove() }
        try fixture.output("", stderr: "simulator unavailable", status: 2)
        let network = SharedFileNetwork(
            fileURL: fixture.directory.appendingPathComponent("network.json"),
            dylibPath: "/builds/current/VirtualNetwork.dylib", injection: fixture.injection, simulator: fixture.simulator)
        let devices = routeDevices { $0.register(.network) { network } }

        await #expect(throws: SimctlCapture.Failure.failed(udid: "U", status: 2, output: "simulator unavailable")) {
            try await Server.networkStateJSON(udid: "U", devices: devices)
        }
    }
}
