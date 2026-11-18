import Testing
import Foundation
import Mockable
@testable import Baguette

/// `POST /simulators/:udid/input` — the HTTP door to the gesture
/// pipeline, so a plugin subprocess can drive the device without
/// holding a WebSocket open. Same `GestureDispatcher` the stream socket
/// and `baguette input` use.
@Suite("Server input route")
struct InputRouteTests {

    @Test func `should press a key on the device when a key envelope is posted`() async throws {
        let input = InputMocks()
        given(input.key).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let outcome = await Server.dispatchInput(
            udid: "U",
            body: #"{"type":"key","code":"KeyR","modifiers":["command"]}"#,
            devices: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        #expect(ack.contains("\"ok\":true"))
        verify(input.key).key(.any, modifiers: .value([.command]), duration: .any).called(1)
    }

    @Test func `should tap the device when a tap envelope is posted`() async throws {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)

        let outcome = await Server.dispatchInput(
            udid: "U",
            body: #"{"type":"tap","x":100,"y":200,"width":390,"height":844}"#,
            devices: Self.simulators(input: input)
        )
        guard case .ok = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        verify(input.touch).tap(at: .value(Point(x: 100, y: 200)), size: .any, duration: .any, edge: .any).called(1)
    }

    @Test func `should report an unknown device when input is posted to an unknown udid`() async throws {
        let simulators = routeDevices()
        let outcome = await Server.dispatchInput(
            udid: "nope", body: #"{"type":"tap","x":1,"y":1,"width":10,"height":10}"#,
            devices: simulators
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should answer a not-ok ack rather than crash when the envelope is malformed`() async throws {
        let input = InputMocks()
        let outcome = await Server.dispatchInput(
            udid: "U", body: "not json", devices: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok ack, got \(outcome)"); return }
        #expect(ack.contains("\"ok\":false"))
    }

    // MARK: - helpers

    static func simulators(input: InputMocks) -> any Devices {
        routeDevices { $0 = .input(of: "iPhone 17", all: input) }
    }

    @Test func `should refuse a key for a device on a cable that has only a touchscreen, naming it`() async throws {
        let touch = MockTouch()
        let phone = routeDevices(name: "han's iPhone") { $0.register(.touch) { touch } }

        let outcome = await Server.dispatchInput(udid: "U", body: #"{"type":"key","code":"KeyA"}"#, devices: phone)

        #expect(outcome == .ok(#"{"ok":false,"error":"han's iPhone can't do key"}"#))
    }

    @Test func `should answer input and describe-ui under the devices tree and a simulator's old one`() {
        for leaf in ["input", "describe-ui.json"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }
}
