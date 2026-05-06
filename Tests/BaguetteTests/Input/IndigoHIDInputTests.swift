import Testing
import Foundation
import Mockable
@testable import Baguette

/// Unit tests for `IndigoHIDInput`'s host-resolution branch — the
/// only branch we can exercise without a real booted simulator.
///
/// The actual `IndigoHIDMessageForMouseNSEvent` 9-arg dispatch
/// path is integration-only: it links into private SimulatorKit
/// symbols, must run on `MainActor`, and silently drops messages
/// when its preconditions aren't met. We don't try to mock that;
/// we exercise the gate that decides whether to even attempt it.
@Suite("IndigoHIDInput — error paths")
struct IndigoHIDInputErrorTests {

    @Test func `tap returns false when host has no matching device`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let input = IndigoHIDInput(udid: "ghost", host: host)

        let ok = input.tap(
            at: Point(x: 10, y: 20),
            size: Size(width: 100, height: 200),
            duration: 0.05
        )
        #expect(!ok)
    }

    @Test func `swipe returns false when host has no matching device`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let input = IndigoHIDInput(udid: "ghost", host: host)

        let ok = input.swipe(
            from: Point(x: 0, y: 0),
            to:   Point(x: 100, y: 200),
            size: Size(width: 100, height: 200),
            duration: 0.25
        )
        #expect(!ok)
    }

    @Test func `touch1 returns false when host has no matching device`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let input = IndigoHIDInput(udid: "ghost", host: host)

        let ok = input.touch1(
            phase: .down,
            at: Point(x: 10, y: 20),
            size: Size(width: 100, height: 200)
        )
        #expect(!ok)
    }

    @Test func `key returns false when host has no matching device`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let input = IndigoHIDInput(udid: "ghost", host: host)

        guard let key = KeyboardKey.from(wireCode: "KeyA") else {
            #expect(Bool(false), "KeyA should resolve")
            return
        }
        let ok = input.key(key, modifiers: [], duration: 0.05)
        #expect(!ok)
    }
}
