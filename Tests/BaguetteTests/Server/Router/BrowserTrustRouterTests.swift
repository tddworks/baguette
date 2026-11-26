import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Who may drive the server from a browser, as the router enforces it in
/// front of the control routes — not the trust rule alone, but that every
/// route actually asks it.
@Suite("Serve router: browser trust")
struct BrowserTrustRouterTests {

    @Test func `should answer a control route when the caller sends no Origin`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(.get, "/devices/U/device.json")

            #expect(response.status == .ok)
        }
    }

    @Test func `should answer a control route when the page is on the server's own loopback origin`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(
                .get, "/devices/U/device.json", headers: [.origin: "http://localhost:8421"])

            #expect(response.status == .ok)
        }
    }

    @Test func `should forbid a control route when a foreign site's page asks`() async throws {
        try await InProcessServer().test { client in
            for path in ["/simulators.json", "/devices/U/device.json", "/devices/U/chrome.json",
                         "/devices/U/hinge", "/devices.json"] {
                let response = try await client.send(
                    .get, path, headers: [.origin: "https://example.test"])

                #expect(response.status == .forbidden, "\(path)")
                #expect(response.json["error"] as? String == "forbidden origin", "\(path)")
            }
        }
    }

    @Test func `should forbid a state-changing route when a foreign site's page posts`() async throws {
        try await InProcessServer().test { client in
            for path in ["/devices/U/boot", "/devices/U/shutdown", "/devices/U/location",
                         "/devices/U/motion", "/devices/U/network", "/devices/U/hinge"] {
                let response = try await client.send(
                    .post, path, body: "{}", headers: [.origin: "https://example.test"])

                #expect(response.status == .forbidden, "\(path)")
            }
        }
    }

    @Test func `should forbid a control route when Fetch Metadata marks the request cross-site`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(
                .get, "/devices/U/device.json", headers: [HTTPField.Name("Sec-Fetch-Site")!: "cross-site"])

            #expect(response.status == .forbidden)
        }
    }

    @Test func `should let an allowed host's page read a response across origins`() async throws {
        try await InProcessServer(allowedHosts: ["app.example.test"]).test { client in
            let response = try await client.send(
                .get, "/devices/U/device.json", headers: [.origin: "https://app.example.test"])

            #expect(response.status == .ok)
            #expect(response.headers[.accessControlAllowOrigin] == "https://app.example.test")
            #expect(response.headers[.accessControlAllowCredentials] == "true")
        }
    }

    @Test func `should name no allowed origin when the page is on a host outside the allowed list`() async throws {
        try await InProcessServer(allowedHosts: ["app.example.test"]).test { client in
            let response = try await client.send(
                .get, "/devices/U/device.json", headers: [.origin: "https://attacker.test"])

            #expect(response.status == .forbidden)
            #expect(response.headers[.accessControlAllowOrigin] == nil)
        }
    }

    @Test func `should answer an allowed host's preflight without reaching a route`() async throws {
        try await InProcessServer(allowedHosts: ["app.example.test"]).test { client in
            let response = try await client.send(
                .options, "/devices/U/boot",
                headers: [.origin: "https://app.example.test", .accessControlRequestMethod: "POST"])

            #expect(response.status == .noContent)
            #expect(response.headers[.accessControlAllowMethods] == "POST")
        }
    }

    @Test func `should forbid a DNS-rebound Host when the server is bound to loopback`() async throws {
        let response = try await InProcessServer().respond(
            .get, "/devices/U/device.json", authority: "attacker.test:8421")

        #expect(response.status == .forbidden)
    }

    @Test func `should answer a proxied Host when it is an allowed host`() async throws {
        let response = try await InProcessServer(allowedHosts: ["sim.example.test"]).respond(
            .get, "/devices/U/device.json", authority: "sim.example.test")

        #expect(response.status == .ok)
    }
}

/// A plugin presents the grant its command was handed; the router lets it
/// reach exactly the routes its manifest declared.
@Suite("Serve router: plugin grants")
struct PluginGrantRouterTests {

    private static let token = HTTPField.Name("X-Baguette-Token")!

    @Test func `should refuse a plugin whose grant is no longer valid`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(
                .get, "/simulators.json", headers: [Self.token: "revoked"])

            #expect(response.status == .forbidden)
            #expect(response.json["error"] as? String == "this grant is no longer valid")
        }
    }

    @Test func `should refuse a plugin a route its manifest did not declare`() async throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "audit", capabilities: [.screenshot])

        try await InProcessServer(grants: grants).test { client in
            let response = try await client.send(
                .get, "/simulators.json", headers: [Self.token: token])

            #expect(response.status == .forbidden)
            #expect(response.json["error"] as? String
                == #"this plugin did not declare the "simulators" capability"#)
        }
    }

    @Test func `should refuse a plugin a route no capability grants`() async throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "audit", capabilities: PluginCapability.allCases)

        try await InProcessServer(grants: grants).test { client in
            let response = try await client.send(
                .get, "/devices/U/device.json", headers: [Self.token: token])

            #expect(response.status == .forbidden)
        }
    }

    @Test func `should let a plugin reach a route its manifest declared`() async throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "audit", capabilities: [.simulators])
        let simulators = MockSimulators()
        given(simulators).all.willReturn([])

        try await InProcessServer(simulators: simulators, grants: grants).test { client in
            let response = try await client.send(
                .get, "/simulators.json", headers: [Self.token: token])

            #expect(response.status == .ok)
            #expect(response.text == #"{"available":[],"running":[]}"#)
        }
    }
}

/// The old `/simulators/:udid/…` tree still answers, and says where to move.
@Suite("Serve router: simulator tree deprecation")
struct SimulatorTreeDeprecationRouterTests {

    @Test func `should mark an old per-device route deprecated, naming its devices successor`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(.get, "/simulators/U/device.json")

            #expect(response.status == .ok)
            #expect(response.header("Deprecation") == "true")
            #expect(response.header("Link") == #"</devices/U/device.json>; rel="successor-version""#)
        }
    }

    @Test func `should mark an old route deprecated even when it refuses`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(.get, "/simulators/ghost/device.json")

            #expect(response.status == .notFound)
            #expect(response.header("Deprecation") == "true")
        }
    }

    @Test func `should not deprecate the devices tree or the simulator list`() async throws {
        let simulators = MockSimulators()
        given(simulators).all.willReturn([])
        try await InProcessServer(simulators: simulators).test { client in
            for path in ["/devices/U/device.json", "/simulators.json"] {
                let response = try await client.send(.get, path)

                #expect(response.header("Deprecation") == nil, "\(path)")
                #expect(response.header("Link") == nil, "\(path)")
            }
        }
    }
}

/// How a route refuses, the same on both trees: no such device (404), a
/// device that can't (422), one that isn't running or is claimed twice (409).
@Suite("Serve router: refusals")
struct RefusalRouterTests {

    @Test func `should answer the same device under both trees`() async throws {
        try await InProcessServer().test { client in
            for path in bothTrees("device.json") {
                let response = try await client.send(.get, path)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["id"] as? String == "U", "\(path)")
            }
        }
    }

    @Test func `should answer not found when no device has the id`() async throws {
        try await InProcessServer().test { client in
            for path in bothTrees("device.json", udid: "ghost") {
                let response = try await client.send(.get, path)

                #expect(response.status == .notFound, "\(path)")
                #expect(response.json["error"] as? String == "unknown udid: ghost", "\(path)")
            }
            for path in bothTrees("boot", udid: "ghost") {
                let response = try await client.send(.post, path)

                #expect(response.status == .notFound, "\(path)")
            }
        }
    }

    @Test func `should answer unprocessable when the device can't do what the route asks`() async throws {
        try await InProcessServer().test { client in
            for path in bothTrees("boot") {
                let response = try await client.send(.post, path)

                #expect(response.status == .unprocessableContent, "\(path)")
            }
        }
    }

    @Test func `should answer conflict when the device isn't running`() async throws {
        let devices = routeDevices(state: .off) { $0.register(.hinge) { MockHinge() } }

        try await InProcessServer(devices: devices).test { client in
            for path in bothTrees("hinge?pose=open") {
                let response = try await client.send(.post, path)

                #expect(response.status == .conflict, "\(path)")
            }
        }
    }

    @Test func `should answer conflict when two sources claim the device`() async throws {
        let devices = MockDevices()
        given(devices).all.willReturn([])
        given(devices).find(id: .any).willThrow(DeviceError.claimedTwice(id: "U"))

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(.post, "/devices/U/boot")

            #expect(response.status == .conflict)
        }
    }
}
