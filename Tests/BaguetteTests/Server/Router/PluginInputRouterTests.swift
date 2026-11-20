import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The plugin list, a plugin's command, posted input and the UI
/// description — the routes plugins drive — as the router answers them.
@Suite("Serve router: plugins and input")
struct PluginInputRouterTests {

    private static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 100, height: 100))

    @Test func `should list the installed plugins`() async throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([])

        try await InProcessServer(plugins: plugins).test { client in
            let response = try await client.send(.get, "/plugins.json")

            #expect(response.status == .ok)
            #expect(response.text == #"{"plugins":[]}"#)
        }
    }

    @Test func `should list no plugins when the plugins can't be read`() async throws {
        let plugins = MockPlugins()
        given(plugins).all().willThrow(RoleFailed())

        try await InProcessServer(plugins: plugins).test { client in
            let response = try await client.send(.get, "/plugins.json")

            #expect(response.text == #"{"plugins":[]}"#)
        }
    }

    @Test func `should answer not found for a command no plugin contributes`() async throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([])

        try await InProcessServer(plugins: plugins).test { client in
            let response = try await client.send(
                .post, "/plugins/audit/commands/run?udid=U", body: #"{"args":{"level":"AA"}}"#)

            #expect(response.status == .notFound)
        }
    }

    @Test func `should forbid a foreign site from running a plugin command`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/plugins/audit/commands/run",
                                        headers: [.origin: "https://example.test"]) == .forbidden)
            #expect(await client.status(.get, "/plugins.json",
                                        headers: [.origin: "https://example.test"]) == .forbidden)
        }
    }

    @Test func `should tap the device with a posted envelope under both trees`() async throws {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let devices = routeDevices { $0 = .input(of: "iPhone 17", all: input) }

        try await InProcessServer(devices: devices).test { client in
            for path in bothTrees("input") {
                let response = try await client.send(
                    .post, path, body: #"{"type":"tap","x":1,"y":2,"width":10,"height":20}"#)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["ok"] as? Bool == true, "\(path)")
            }
        }
    }

    @Test func `should keep a device's input across posted taps, not connect afresh for each`() async throws {
        let made = TouchesMade()
        let devices = routeDevices {
            $0.register(.touch) {
                made.increment()
                let touch = MockTouch()
                given(touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
                return touch
            }
        }

        try await InProcessServer(devices: devices).test { client in
            for _ in 0..<3 {
                let response = try await client.send(
                    .post, "/devices/U/input", body: #"{"type":"tap","x":1,"y":2,"width":10,"height":20}"#)
                #expect(response.json["ok"] as? Bool == true)
            }
        }

        #expect(made.value == 1)
    }

    @Test func `should refuse input to a device that isn't running or doesn't exist`() async throws {
        let devices = routeDevices(state: .off) { $0.register(.touch) { MockTouch() } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.post, "/devices/ghost/input", body: "{}") == .notFound)
        }
        let unavailable = MockDevices()
        given(unavailable).all.willReturn([])
        given(unavailable).find(id: .any).willThrow(DeviceError.claimedTwice(id: "U"))
        try await InProcessServer(devices: unavailable).test { client in
            #expect(await client.status(.post, "/devices/U/input", body: "{}") == .conflict)
        }
    }

    @Test func `should describe the frontmost app's UI, or the element under a point`() async throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(AXNode(role: "AXApplication", frame: Self.frame))
        given(ax).describeAt(point: .any).willReturn(AXNode(role: "AXButton", frame: Self.frame))
        let devices = routeDevices { $0.register(.accessibility) { ax } }

        try await InProcessServer(devices: devices).test { client in
            let all = try await client.send(.get, "/devices/U/describe-ui.json")
            let one = try await client.send(.get, "/simulators/U/describe-ui.json?x=5&y=5")

            #expect((all.json["tree"] as? [String: Any])?["role"] as? String == "AXApplication")
            #expect((one.json["tree"] as? [String: Any])?["role"] as? String == "AXButton")
        }
    }

    @Test func `should describe no UI when no app is frontmost`() async throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(nil)
        let devices = routeDevices { $0.register(.accessibility) { ax } }

        try await InProcessServer(devices: devices).test { client in
            let response = try await client.send(.get, "/devices/U/describe-ui.json")

            #expect(response.status == .ok)
            #expect(response.json["error"] as? String == "no accessibility data")
        }
    }

    @Test func `should answer a server error when the UI can't be described`() async throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.accessibility) { ax } }

        try await InProcessServer(devices: devices).test { client in
            #expect(await client.status(.get, "/devices/U/describe-ui.json") == .internalServerError)
        }
    }

    @Test func `should refuse to describe a device that can't or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.get, "/devices/U/describe-ui.json") == .unprocessableContent)
            #expect(await client.status(.get, "/devices/ghost/describe-ui.json") == .notFound)
        }
    }
}

private final class TouchesMade: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var value: Int { lock.withLock { made } }
    func increment() { lock.withLock { made += 1 } }
}
