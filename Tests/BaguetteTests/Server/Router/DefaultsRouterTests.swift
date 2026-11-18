import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An app's preferences, its installed apps and a relaunch, as the router
/// answers them — each outcome on its status.
@Suite("Serve router: defaults")
struct DefaultsRouterTests {

    private static func host(failure: DefaultsError? = nil) -> any Devices {
        let defaults = MockDefaults()
        let apps = MockApps()
        if let failure {
            given(defaults).read(.any).willThrow(failure)
            given(defaults).write(.any, forKey: .any, in: .any).willThrow(failure)
            given(defaults).delete(key: .any, in: .any).willThrow(failure)
            given(defaults).groups(of: .any).willThrow(failure)
            given(apps).terminate(bundleID: .any).willThrow(failure)
            given(apps).installed().willThrow(failure)
        } else {
            given(defaults).read(.any).willReturn(Preferences(values: ["seen": .bool(false)]))
            given(defaults).write(.any, forKey: .any, in: .any).willReturn()
            given(defaults).delete(key: .any, in: .any).willReturn()
            given(defaults).groups(of: .any).willReturn(["group.x"])
            given(apps).terminate(bundleID: .any).willReturn()
            given(apps).installed().willReturn([
                InstalledApp(bundleIdentifier: "com.x.app", name: "Alpha"),
            ])
        }
        given(defaults).lookups(of: .any).willReturn(nil)
        given(apps).launch(bundleID: .any).willReturn()
        return routeDevices {
            $0.register(.defaults) { defaults }
            $0.register(.apps) { apps }
        }
    }

    @Test func `should read an app's preferences under both trees`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            for path in bothTrees("defaults.json?bundleId=com.x") {
                let response = try await client.send(.get, path)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["bundleId"] as? String == "com.x", "\(path)")
            }
        }
    }

    @Test func `should write a preference and say whether the app relaunched`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let response = try await client.send(
                .post, "/devices/U/defaults",
                body: #"{"bundleId":"com.x","key":"seen","type":"bool","value":true,"relaunch":false}"#)

            #expect(response.status == .ok)
            #expect(response.json["relaunched"] as? Bool == false)
        }
    }

    @Test func `should import a set of preferences`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let response = try await client.send(
                .post, "/devices/U/defaults",
                body: #"{"bundleId":"com.x","values":{"seen":{"type":"bool","value":true}},"relaunch":false}"#)

            #expect(response.status == .ok)
            #expect(response.json["written"] as? Int == 1)
        }
    }

    @Test func `should remove a preference`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let response = try await client.send(.delete, "/devices/U/defaults?bundleId=com.x&key=seen")

            #expect(response.status == .ok)
            #expect(response.json["removed"] != nil)
        }
    }

    @Test func `should list installed apps, the app's groups and relaunch it`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let apps = try await client.send(.get, "/devices/U/apps.json")
            let groups = try await client.send(.get, "/devices/U/defaults-groups.json?bundleId=com.x")
            let relaunch = try await client.send(.post, "/devices/U/relaunch?bundleId=com.x")

            #expect((apps.json["apps"] as? [[String: Any]])?.first?["name"] as? String == "Alpha")
            #expect(groups.json["groups"] as? [String] == ["group.x"])
            #expect(relaunch.status == .ok)
        }
    }

    @Test func `should refuse a defaults request that names no app, key or valid value`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            #expect(await client.status(.get, "/devices/U/defaults.json") == .badRequest)
            #expect(await client.status(.post, "/devices/U/defaults", body: "[]") == .badRequest)
            #expect(await client.status(.post, "/devices/U/defaults", body: #"{"bundleId":"com.x"}"#)
                == .badRequest)
            #expect(await client.status(.post, "/devices/U/defaults",
                                        body: #"{"bundleId":"com.x","key":"k","type":"nope"}"#) == .badRequest)
            #expect(await client.status(.post, "/devices/U/defaults",
                                        body: #"{"bundleId":"com.x","key":"k","type":"bool"}"#) == .badRequest)
            #expect(await client.status(.post, "/devices/U/defaults",
                                        body: #"{"bundleId":"com.x","key":"k","type":"bool","value":true,"relaunch":"x"}"#)
                == .badRequest)
            #expect(await client.status(.post, "/devices/U/defaults",
                                        body: #"{"values":{},"relaunch":"x"}"#) == .badRequest)
            #expect(await client.status(.delete, "/devices/U/defaults?bundleId=com.x") == .badRequest)
            #expect(await client.status(.delete, "/devices/U/defaults?bundleId=com.x&key=k&relaunch=x")
                == .badRequest)
            #expect(await client.status(.get, "/devices/U/defaults-groups.json") == .badRequest)
            #expect(await client.status(.post, "/devices/U/relaunch") == .badRequest)
        }
    }

    @Test func `should answer not found when the app isn't installed`() async throws {
        let devices = Self.host(failure: .appNotInstalled(bundleID: "com.x"))

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.get, "/devices/U/defaults.json?bundleId=com.x") == .notFound)
            #expect(await client.status(.get, "/devices/U/defaults-groups.json?bundleId=com.x") == .notFound)
            #expect(await client.status(.post, "/devices/U/relaunch?bundleId=com.x") == .notFound)
        }
    }

    @Test func `should answer conflict when the device is shut down`() async throws {
        let devices = Self.host(failure: .deviceNotBooted)

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.get, "/devices/U/defaults.json?bundleId=com.x") == .conflict)
            #expect(await client.status(.post, "/devices/U/defaults",
                                        body: #"{"bundleId":"com.x","key":"k","type":"bool","value":true}"#)
                == .conflict)
            #expect(await client.status(.delete, "/devices/U/defaults?bundleId=com.x&key=k") == .conflict)
        }
    }

    @Test func `should answer a server error when simctl fails`() async throws {
        let devices = Self.host(failure: .simctlFailed(status: 1))

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.get, "/devices/U/apps.json") == .internalServerError)
            #expect(await client.status(.post, "/devices/U/defaults",
                                        body: #"{"bundleId":"com.x","values":{"k":{"type":"bool","value":true}}}"#)
                == .internalServerError)
        }
    }

    @Test func `should refuse defaults on a device that has none or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            for udid in ["U", "ghost"] {
                let expected: HTTPResponse.Status = udid == "U" ? .unprocessableContent : .notFound
                #expect(await client.status(.get, "/devices/\(udid)/defaults.json?bundleId=com.x") == expected)
                #expect(await client.status(.post, "/devices/\(udid)/defaults",
                                            body: #"{"bundleId":"com.x","key":"k","type":"bool","value":true}"#)
                    == expected)
                #expect(await client.status(.post, "/devices/\(udid)/defaults",
                                            body: #"{"bundleId":"com.x","values":{}}"#) == expected)
                #expect(await client.status(.get, "/devices/\(udid)/apps.json") == expected)
                #expect(await client.status(.get, "/devices/\(udid)/defaults-groups.json?bundleId=com.x") == expected)
                #expect(await client.status(.post, "/devices/\(udid)/relaunch?bundleId=com.x") == expected)
            }
        }
    }
}
