import Testing
import Foundation
import Mockable
@testable import Baguette

/// `DeviceHost` is the seam Infrastructure adapters
/// (`IndigoHIDInput`, `AXPTranslatorAccessibility`,
/// `SimDeviceLogStream`) take instead of the concrete
/// `CoreSimulators` class. It exposes the one capability they
/// need — looking up a live `SimDevice` `NSObject` for a UDID —
/// and lets tests inject `MockDeviceHost` fakes for the error-path
/// branches that don't require the real CoreSimulator daemon.
@Suite("DeviceHost port")
struct DeviceHostTests {

    @Test func `DeviceHost can be mocked and returns a stub device`() {
        let host = MockDeviceHost()
        let stub = NSObject()
        given(host).resolveDevice(udid: .value("u1")).willReturn(stub)

        #expect(host.resolveDevice(udid: "u1") === stub)
        verify(host).resolveDevice(udid: .value("u1")).called(1)
    }

    @Test func `DeviceHost returns nil for an unknown UDID`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)

        #expect(host.resolveDevice(udid: "ghost") == nil)
    }

    @Test func `CoreSimulators conforms to DeviceHost`() {
        // Compile-time witness: a CoreSimulators instance is
        // assignable to `any DeviceHost`. The runtime device set
        // is irrelevant for this test — we don't dereference it.
        let live: any DeviceHost = CoreSimulators(deviceSetPath: "/dev/null")
        _ = live
    }
}
