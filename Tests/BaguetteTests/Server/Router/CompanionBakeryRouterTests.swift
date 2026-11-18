import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The companion screens rail and CarPlay's reattach, as the router
/// answers them.
@Suite("Serve router: companion screens")
struct CompanionScreenRouterTests {

    private static func host(reattachFails: Bool = false) -> any Devices {
        let display = MockDisplay()
        let displays = MockDisplays()
        let pairing = MockWatchPairing()
        let external = MockExternalDisplays()
        given(display).resolve().willReturn(DisplayBinding(
            kind: .carPlay, connectedScreenId: 3, portName: "com.apple.framebuffer.display",
            size: Size(width: 720, height: 480)))
        given(displays).carPlay.willReturn(display)
        given(pairing).watch.willReturn(nil)
        if reattachFails {
            given(external).reattachCarPlay().willThrow(RoleFailed())
        } else {
            given(external).reattachCarPlay().willReturn()
        }
        return routeDevices {
            $0.register(.displays) { displays }
            $0.register(.watchPairing) { pairing }
            $0.register(.externalDisplays) { external }
        }
    }

    @Test func `should offer the companion screens a device has under both trees`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            for path in bothTrees("companion-screens.json") {
                let response = try await client.send(.get, path)

                #expect(response.status == .ok, "\(path)")
                #expect((response.json["external"] as? [String: Any])?["available"] as? Bool == true, "\(path)")
            }
        }
    }

    @Test func `should reattach CarPlay and answer with the screens it now offers`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let response = try await client.send(.post, "/devices/U/carplay-display")

            #expect(response.status == .ok)
            #expect(response.json["watch"] != nil)
        }
    }

    @Test func `should say how to grant access when Simulator.app can't be driven`() async throws {
        try await InProcessServer(devices: Self.host(reattachFails: true)).test { client in
            let response = try await client.send(.post, "/devices/U/carplay-display")

            #expect(response.status == .internalServerError)
            #expect((response.json["error"] as? String)?.contains("Privacy & Security") == true)
        }
    }

    @Test func `should refuse the companion screens of a device that has none or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.get, "/devices/U/companion-screens.json") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/U/carplay-display") == .unprocessableContent)
            #expect(await client.status(.get, "/devices/ghost/companion-screens.json") == .notFound)
            #expect(await client.status(.post, "/devices/ghost/carplay-display") == .notFound)
        }
    }
}

/// The bakery routes, for what they decide without reaching a remote.
@Suite("Serve router: bakeries")
struct BakeryRouterTests {

    @Test func `should refuse to preview a bakery reference it can't read`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/bakeries/preview", body: #"{"ref":""}"#) == .badRequest)
        }
    }

    @Test func `should refuse to install from a bakery the user never trusted`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(
                .post, "/bakeries/install",
                body: #"{"bakery":"router-test-no-such-bakery","plugin":"x"}"#) == .forbidden)
        }
    }

    @Test func `should forbid a foreign site from previewing, installing or listing bakeries`() async throws {
        try await InProcessServer().test { client in
            let foreign: HTTPFields = [.origin: "https://example.test"]
            #expect(await client.status(.post, "/bakeries/preview", body: "{}", headers: foreign) == .forbidden)
            #expect(await client.status(.post, "/bakeries/install", body: "{}", headers: foreign) == .forbidden)
            #expect(await client.status(.get, "/bakeries.json", headers: foreign) == .forbidden)
        }
    }
}
