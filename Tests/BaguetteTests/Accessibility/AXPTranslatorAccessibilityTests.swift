import Testing
import Foundation
import Mockable
@testable import Baguette

/// Unit tests for `AXPTranslatorAccessibility`'s host-resolution
/// branches — the only paths we can exercise without a live
/// AXPTranslator + bridge-token-delegate handshake.
///
/// The actual XPC round-trip into the simulator's accessibility
/// service depends on private framework load + dispatcher install
/// + `frontmostApplicationWithDisplayId:` returning a usable
/// translation. That path is integration-only — manually
/// smoke-tested via `baguette describe-ui` against a booted sim.
@Suite("AXPTranslatorAccessibility — error paths")
struct AXPTranslatorAccessibilityErrorTests {

    @Test func `AX observations reject changed orientation size or panel`() throws {
        let before = AXScreen(
            width: 402, height: 874, orientation: .portrait,
            target: ScreenTarget(screenId: 1, litPanel: nil, pixelSize: Size(width: 1206, height: 2622)))
        try AXPTranslatorAccessibility.requireUnchanged(before, before)
        let changed: [AXPTranslatorAccessibility.DisplayGeometry] = [
            AXScreen(width: 402, height: 874, orientation: .landscapeLeft, target: before.target),
            AXScreen(width: 744, height: 1133, orientation: .portrait, target: before.target),
            AXScreen(
                width: 402, height: 874, orientation: .portrait,
                target: ScreenTarget(screenId: 2, litPanel: nil, pixelSize: Size(width: 1206, height: 2622))),
        ]
        for after in changed {
            #expect(throws: AXPTranslatorAccessibility.Failure.displayChanged) {
                try AXPTranslatorAccessibility.requireUnchanged(before, after)
            }
        }
    }

    @Test func `an unobservable display fails the query instead of guessing a screen`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(NSObject())
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        // The geometry is read before any AXP work: a device that is present
        // but cannot name its screen is an error, not an empty tree.
        #expect(throws: ObservedScreenError.unavailable) { try ax.describeAll() }
        #expect(throws: ObservedScreenError.unavailable) { try ax.describeAt(point: Point(x: 10, y: 20)) }
    }

    @Test func `a changed display tells the caller to observe again`() {
        #expect(
            AXPTranslatorAccessibility.Failure.displayChanged.localizedDescription
                == "The display changed while reading accessibility; discard the result and observe again.")
    }

    @Test func `describeAll returns nil when host has no matching device`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        #expect(try ax.describeAll() == nil)
    }

    @Test func `describeAt returns nil when host has no matching device`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        #expect(try ax.describeAt(point: Point(x: 10, y: 20)) == nil)
    }
}
