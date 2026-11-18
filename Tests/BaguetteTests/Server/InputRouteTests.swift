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
            simulators: Self.simulators(input: input)
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
            simulators: Self.simulators(input: input)
        )
        guard case .ok = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        verify(input.touch).tap(at: .value(Point(x: 100, y: 200)), size: .any, duration: .any, edge: .any).called(1)
    }

    @Test func `should report an unknown device when input is posted to an unknown udid`() async throws {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        let outcome = await Server.dispatchInput(
            udid: "nope", body: #"{"type":"tap","x":1,"y":1,"width":10,"height":10}"#,
            simulators: simulators
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should answer a not-ok ack rather than crash when the envelope is malformed`() async throws {
        let input = InputMocks()
        let outcome = await Server.dispatchInput(
            udid: "U", body: "not json", simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok ack, got \(outcome)"); return }
        #expect(ack.contains("\"ok\":false"))
    }

    // MARK: - helpers

    static func simulators(input: InputMocks) -> MockSimulators {
        let sim = MockSimulator()
        given(sim).input().willReturn(input)
        given(sim).name.willReturn("iPhone 17")
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        return simulators
    }
}
