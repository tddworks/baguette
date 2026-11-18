import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Orientation, shake and the status bar, as the router answers them.
@Suite("Serve router: screen state")
struct ScreenStateRouterTests {

    // MARK: - orientation

    private static func turning(_ delivery: PoseDelivery) -> any Devices {
        let orientation = MockOrientation()
        given(orientation).set(.any).willReturn(delivery)
        return routeDevices { $0.register(.orientation) { orientation } }
    }

    @Test func `should turn the device to the orientation asked for under both trees`() async throws {
        try await InProcessServer(devices: Self.turning(.delivered)).test { client in
            for path in bothTrees("orientation?value=landscape-left") {
                #expect(await client.status(.post, path) == .ok, "\(path)")
            }
        }
    }

    @Test func `should refuse an orientation that names no pose`() async throws {
        try await InProcessServer(devices: Self.turning(.delivered)).test { client in
            #expect(await client.status(.post, "/devices/U/orientation?value=sideways") == .badRequest)
        }
    }

    @Test func `should answer a server error when the guest rejects the turn`() async throws {
        try await InProcessServer(devices: Self.turning(.rejected)).test { client in
            #expect(await client.status(.post, "/devices/U/orientation?value=portrait")
                == .internalServerError)
        }
    }

    @Test func `should answer a gateway timeout when the turn is unconfirmed`() async throws {
        try await InProcessServer(devices: Self.turning(.unconfirmed)).test { client in
            #expect(await client.status(.post, "/devices/U/orientation?value=portrait")
                == .gatewayTimeout)
        }
    }

    @Test func `should refuse to turn a device that can't turn or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/orientation?value=portrait")
                == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/orientation?value=portrait")
                == .notFound)
        }
    }

    // MARK: - shake

    @Test func `should shake the device`() async throws {
        let shake = MockShake()
        given(shake).shake().willReturn()
        let devices = routeDevices { $0.register(.shake) { shake } }

        try await InProcessServer(devices: devices).test { client in
            for path in bothTrees("shake") {
                #expect(await client.status(.post, path) == .ok, "\(path)")
            }
        }
    }

    @Test func `should answer a server error when the shake fails`() async throws {
        let shake = MockShake()
        given(shake).shake().willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.shake) { shake } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.post, "/devices/U/shake") == .internalServerError)
        }
    }

    @Test func `should refuse to shake a device that can't or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/shake") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/shake") == .notFound)
        }
    }

    // MARK: - status bar

    private static func statusBar(failing: Bool = false) -> any Devices {
        let statusBar = MockStatusBar()
        if failing {
            given(statusBar).override(.any).willThrow(RoleFailed())
            given(statusBar).clear().willThrow(RoleFailed())
            given(statusBar).read().willThrow(RoleFailed())
        } else {
            given(statusBar).override(.any).willReturn()
            given(statusBar).clear().willReturn()
            var override = StatusBarOverride()
            override.time = "9:41"
            given(statusBar).read().willReturn(override)
        }
        return routeDevices { $0.register(.statusBar) { statusBar } }
    }

    @Test func `should override, read and clear the status bar under both trees`() async throws {
        try await InProcessServer(devices: Self.statusBar()).test { client in
            for path in bothTrees("status-bar") {
                #expect(await client.status(.post, path, body: #"{"time":"9:41"}"#) == .ok, "\(path)")
                let read = try await client.send(.get, path)
                #expect(read.status == .ok, "\(path)")
                #expect(read.json["time"] as? String == "9:41", "\(path)")
                #expect(await client.status(.delete, path) == .ok, "\(path)")
            }
        }
    }

    @Test func `should refuse a status-bar body that isn't an override or sets nothing`() async throws {
        try await InProcessServer(devices: Self.statusBar()).test { client in
            #expect(await client.status(.post, "/devices/U/status-bar", body: "nope") == .badRequest)
            let empty = try await client.send(.post, "/devices/U/status-bar", body: "{}")
            #expect(empty.status == .badRequest)
            #expect(empty.json["error"] as? String == "set at least one status-bar field")
        }
    }

    @Test func `should answer a server error when the status bar can't be changed or read`() async throws {
        try await InProcessServer(devices: Self.statusBar(failing: true)).test { client in
            #expect(await client.status(.post, "/devices/U/status-bar", body: #"{"time":"1"}"#)
                == .internalServerError)
            #expect(await client.status(.get, "/devices/U/status-bar") == .internalServerError)
            #expect(await client.status(.delete, "/devices/U/status-bar") == .internalServerError)
        }
    }

    @Test func `should refuse the status bar of a device that has none or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            for method in [HTTPRequest.Method.post, .get, .delete] {
                #expect(await client.status(method, "/devices/U/status-bar", body: "{}")
                    == .unprocessableContent, "\(method)")
                #expect(await client.status(method, "/devices/ghost/status-bar", body: "{}")
                    == .notFound, "\(method)")
            }
        }
    }
}
