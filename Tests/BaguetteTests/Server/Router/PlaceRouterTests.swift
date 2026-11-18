import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A failure a role reports, for the routes that turn it into a 500.
struct RoleFailed: Error, CustomStringConvertible {
    var description: String { "role failed" }
}

/// Where the device is and how it moves — location, motion, network — as
/// the router answers them under both trees.
@Suite("Serve router: place")
struct PlaceRouterTests {

    // MARK: - location

    @Test func `should pin the device to a posted point under both trees`() async throws {
        let location = MockLocation()
        given(location).set(.any).willReturn()
        let devices = routeDevices { $0.register(.location) { location } }

        try await InProcessServer(devices: devices).test { client in
            for path in bothTrees("location") {
                let response = try await client.send(.post, path, body: #"{"latitude":37.33,"longitude":-122.03}"#)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["ok"] as? Bool == true, "\(path)")
            }
        }
    }

    @Test func `should refuse a location body that is neither a point, a route nor a walk`() async throws {
        let devices = routeDevices { $0.register(.location) { MockLocation() } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(.post, "/devices/U/location", body: "nope")

            #expect(response.status == .badRequest)
        }
    }

    @Test func `should answer a server error when the location can't be set`() async throws {
        let location = MockLocation()
        given(location).set(.any).willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.location) { location } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(
                .post, "/devices/U/location", body: #"{"latitude":1,"longitude":2}"#)

            #expect(response.status == .internalServerError)
        }
    }

    @Test func `should refuse to place a device that has no location`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/location", body: "{}") == .unprocessableContent)
            #expect(await client.status(.delete, "/devices/U/location") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/location", body: "{}") == .notFound)
            #expect(await client.status(.delete, "/devices/ghost/location") == .notFound)
        }
    }

    @Test func `should clear the simulated location back to live`() async throws {
        let location = MockLocation()
        given(location).clear().willReturn()
        let devices = routeDevices { $0.register(.location) { location } }

        try await InProcessServer(devices: devices).test { client in
            for path in bothTrees("location") {
                #expect(await client.status(.delete, path) == .ok, "\(path)")
            }
        }
    }

    @Test func `should answer a server error when the location can't be cleared`() async throws {
        let location = MockLocation()
        given(location).clear().willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.location) { location } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.delete, "/devices/U/location") == .internalServerError)
        }
    }

    // MARK: - motion

    private static func motion(failing: Bool = false) -> MockMotion {
        let motion = MockMotion()
        if failing {
            given(motion).publish(.any).willThrow(RoleFailed())
            given(motion).clear().willThrow(RoleFailed())
        } else {
            given(motion).publish(.any).willReturn()
            given(motion).clear().willReturn()
        }
        given(motion).published().willReturn(nil)
        return motion
    }

    @Test func `should report motion inactive until it is armed`() async throws {
        let devices = routeDevices { $0.register(.motion) { Self.motion() } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(.get, "/devices/U/motion")

            #expect(response.status == .ok)
            #expect(response.json["active"] as? Bool == false)
        }
    }

    @Test func `should arm motion with the activity a page posts and report it active`() async throws {
        let devices = routeDevices { $0.register(.motion) { Self.motion() } }

        try await InProcessServer(devices: devices).test { client in
            let armed = try await client.send(.post, "/simulators/U/motion", body: #"{"activity":"walking"}"#)
            let read = try await client.send(.get, "/devices/U/motion")

            #expect(armed.status == .ok)
            #expect(armed.json["active"] as? Bool == true)
            #expect(read.json["activity"] as? String == "walking")
        }
    }

    @Test func `should refuse a motion body that names no activity`() async throws {
        let devices = routeDevices { $0.register(.motion) { Self.motion() } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(.post, "/devices/U/motion", body: #"{"activity":"flying"}"#)

            #expect(response.status == .badRequest)
        }
    }

    @Test func `should answer a server error when motion can't be armed or stopped`() async throws {
        let devices = routeDevices { $0.register(.motion) { Self.motion(failing: true) } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.post, "/devices/U/motion", body: #"{"activity":"running"}"#)
                == .internalServerError)
            #expect(await client.status(.delete, "/devices/U/motion") == .internalServerError)
        }
    }

    @Test func `should stop motion`() async throws {
        let devices = routeDevices { $0.register(.motion) { Self.motion() } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.delete, "/devices/U/motion") == .ok)
        }
    }

    @Test func `should refuse motion to a device that can't move or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/motion", body: "{}") == .unprocessableContent)
            #expect(await client.status(.delete, "/devices/U/motion") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/motion", body: "{}") == .notFound)
            #expect(await client.status(.delete, "/devices/ghost/motion") == .notFound)
            #expect(await client.status(.get, "/devices/ghost/motion") == .notFound)
        }
    }

    // MARK: - network

    @Test func `should condition the network with a posted profile and report it armed`() async throws {
        let network = MockNetwork()
        let condition = try #require(NetworkProfile(rawValue: "3g")?.condition)
        given(network).apply(.any).willReturn()
        given(network).current().willReturn(condition)
        let devices = routeDevices { $0.register(.network) { network } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(.post, "/devices/U/network", body: #"{"profile":"3g"}"#)

            #expect(response.status == .ok)
            #expect(response.json["active"] as? Bool == true)
            #expect(response.json["profile"] as? String == "3g")
        }
    }

    @Test func `should refuse a network body that names more than one condition`() async throws {
        let devices = routeDevices { $0.register(.network) { MockNetwork() } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(
                .post, "/devices/U/network", body: #"{"profile":"3g","offline":true}"#)

            #expect(response.status == .badRequest)
        }
    }

    @Test func `should answer a server error when the network can't be conditioned`() async throws {
        let network = MockNetwork()
        given(network).apply(.any).willThrow(RoleFailed())
        given(network).clear().willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.network) { network } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.post, "/devices/U/network", body: #"{"offline":true}"#)
                == .internalServerError)
            #expect(await client.status(.delete, "/devices/U/network") == .internalServerError)
        }
    }

    @Test func `should answer a server error when an applied condition can't be read back`() async throws {
        let network = MockNetwork()
        given(network).apply(.any).willReturn()
        given(network).current().willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.network) { network } }

        try await InProcessServer(devices: devices).test { client in
            let applied = try await client.send(.post, "/devices/U/network", body: #"{"offline":true}"#)
            let read = try await client.send(.get, "/devices/U/network")

            #expect(applied.status == .internalServerError)
            #expect((applied.json["error"] as? String)?.hasPrefix("network condition applied") == true)
            #expect(read.status == .internalServerError)
        }
    }

    @Test func `should report an unconditioned network with the profiles it can take`() async throws {
        let network = MockNetwork()
        given(network).current().willReturn(nil)
        given(network).clear().willReturn()
        let devices = routeDevices { $0.register(.network) { network } }

        try await InProcessServer(devices: devices).test { client in
            let read = try await client.send(.get, "/simulators/U/network")

            #expect(read.json["active"] as? Bool == false)
            #expect((read.json["profiles"] as? [String])?.contains("3g") == true)
            #expect(await client.status(.delete, "/devices/U/network") == .ok)
        }
    }

    @Test func `should refuse network conditioning to a device that can't or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.get, "/devices/U/network") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/U/network", body: "{}") == .unprocessableContent)
            #expect(await client.status(.delete, "/devices/U/network") == .unprocessableContent)
            #expect(await client.status(.get, "/devices/ghost/network") == .notFound)
            #expect(await client.status(.post, "/devices/ghost/network", body: "{}") == .notFound)
            #expect(await client.status(.delete, "/devices/ghost/network") == .notFound)
        }
    }
}
