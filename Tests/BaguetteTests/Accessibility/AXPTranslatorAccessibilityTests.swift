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

    @Test func `describeAll returns nil when host has no matching device`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host)

        #expect(try ax.describeAll() == nil)
    }

    @Test func `describeAt returns nil when host has no matching device`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host)

        #expect(try ax.describeAt(point: Point(x: 10, y: 20)) == nil)
    }
}
