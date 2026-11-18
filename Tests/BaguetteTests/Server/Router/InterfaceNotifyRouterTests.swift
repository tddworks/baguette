import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Appearance, contrast and text size, as the router answers them.
@Suite("Serve router: interface")
struct InterfaceRouterTests {

    private static func interface(readFails: Bool = false, setFails: Bool = false) -> any Devices {
        let interface = MockInterface()
        if readFails {
            given(interface).appearance().willThrow(RoleFailed())
        } else {
            given(interface).appearance().willReturn(.dark)
        }
        given(interface).increaseContrast().willReturn(.enabled)
        given(interface).contentSize().willReturn(.large)
        if setFails {
            given(interface).setAppearance(.any).willThrow(RoleFailed())
        } else {
            given(interface).setAppearance(.any).willReturn(())
        }
        given(interface).setIncreaseContrast(.any).willReturn(())
        given(interface).setContentSize(.any).willReturn(())
        return routeDevices { $0.register(.interface) { interface } }
    }

    @Test func `should read the interface settings under both trees`() async throws {
        try await InProcessServer(devices: Self.interface()).test { client in
            for path in bothTrees("interface.json") {
                let response = try await client.send(.get, path)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["appearance"] as? String == "dark", "\(path)")
            }
        }
    }

    @Test func `should answer a server error when the settings can't be read`() async throws {
        try await InProcessServer(devices: Self.interface(readFails: true)).test { client in
            #expect(await client.status(.get, "/devices/U/interface.json") == .internalServerError)
        }
    }

    @Test func `should change the settings a body names and answer with what they read now`() async throws {
        try await InProcessServer(devices: Self.interface()).test { client in
            let response = try await client.send(.post, "/simulators/U/interface", body: #"{"appearance":"dark"}"#)

            #expect(response.status == .ok)
            #expect(response.json["contentSize"] as? String == "large")
        }
    }

    @Test func `should answer with what was applied when the settings can't be read back`() async throws {
        try await InProcessServer(devices: Self.interface(readFails: true)).test { client in
            let response = try await client.send(.post, "/devices/U/interface", body: #"{"appearance":"light"}"#)

            #expect(response.status == .ok)
            #expect(response.json["applied"] as? [String] == ["appearance"])
        }
    }

    @Test func `should answer a server error naming what was applied when a setting fails`() async throws {
        try await InProcessServer(devices: Self.interface(setFails: true)).test { client in
            let response = try await client.send(.post, "/devices/U/interface", body: #"{"appearance":"dark"}"#)

            #expect(response.status == .internalServerError)
            #expect(response.json["applied"] as? [String] == [])
        }
    }

    @Test func `should refuse an interface body that names nothing settable`() async throws {
        try await InProcessServer(devices: Self.interface()).test { client in
            #expect(await client.status(.post, "/devices/U/interface", body: "nope") == .badRequest)
        }
    }

    @Test func `should refuse the interface of a device that has none or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.get, "/devices/U/interface.json") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/U/interface", body: #"{"appearance":"dark"}"#)
                == .unprocessableContent)
            #expect(await client.status(.get, "/devices/ghost/interface.json") == .notFound)
            #expect(await client.status(.post, "/devices/ghost/interface", body: #"{"appearance":"dark"}"#)
                == .notFound)
        }
    }

    @Test func `should let a granted plugin read the interface whatever Origin it sends`() async throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "audit", capabilities: [.interface])

        try await InProcessServer(devices: Self.interface(), grants: grants).test { client in
            let response = try await client.send(
                .get, "/simulators/U/interface.json",
                headers: [HTTPField.Name("X-Baguette-Token")!: token, .origin: "https://example.test"])

            #expect(response.status == .ok)
        }
    }
}

/// A remote notification, as the router delivers it.
@Suite("Serve router: notify")
struct NotifyRouterTests {

    private static let order = #"{"aps":{"alert":"Your order shipped"}}"#

    private static func notify(_ failure: (any Error)? = nil) -> any Devices {
        let notify = MockNotify()
        if let failure {
            given(notify).deliver(.any).willThrow(failure)
        } else {
            given(notify).deliver(.any).willReturn()
        }
        return routeDevices { $0.register(.notify) { notify } }
    }

    @Test func `should deliver a notification to the app the query names under both trees`() async throws {
        try await InProcessServer(devices: Self.notify()).test { client in
            for path in bothTrees("notify?bundleId=com.example.app") {
                #expect(await client.status(.post, path, body: Self.order) == .ok, "\(path)")
            }
        }
    }

    @Test func `should refuse a payload that isn't a notification`() async throws {
        try await InProcessServer(devices: Self.notify()).test { client in
            #expect(await client.status(.post, "/devices/U/notify?bundleId=a.b", body: "{}") == .badRequest)
        }
    }

    @Test func `should answer conflict when the app doesn't allow notifications`() async throws {
        let devices = Self.notify(AppsError.notificationsNotAllowed(app: "a.b"))

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.post, "/devices/U/notify?bundleId=a.b", body: Self.order)
                == .conflict)
        }
    }

    @Test func `should answer a server error when delivery fails`() async throws {
        try await InProcessServer(devices: Self.notify(RoleFailed())).test { client in
            #expect(await client.status(.post, "/devices/U/notify?bundleId=a.b", body: Self.order)
                == .internalServerError)
        }
    }

    @Test func `should refuse to notify a device that can't or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/notify?bundleId=a.b", body: Self.order)
                == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/notify?bundleId=a.b", body: Self.order)
                == .notFound)
        }
    }
}
