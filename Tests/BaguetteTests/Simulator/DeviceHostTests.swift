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

    @Test func `should resolve a device by its udid on a stand-in host`() {
        let host = MockDeviceHost()
        let stub = NSObject()
        given(host).resolveDevice(udid: .value("u1")).willReturn(stub)

        #expect(host.resolveDevice(udid: "u1") === stub)
        verify(host).resolveDevice(udid: .value("u1")).called(1)
    }

    @Test func `should find no device when the udid is unknown`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)

        #expect(host.resolveDevice(udid: "ghost") == nil)
    }

    @Test func `should let the live simulator set act as a device host`() {
        // Compile-time witness: a CoreSimulators instance is
        // assignable to `any DeviceHost`. The runtime device set
        // is irrelevant for this test — we don't dereference it.
        let live: any DeviceHost = CoreSimulators(deviceSetPath: "/dev/null")
        _ = live
    }

    // MARK: - remembering a device

    @objc(FakeHostDevice) private final class FakeDevice: NSObject {
        @objc let UDID: NSUUID
        init(_ udid: NSUUID) { UDID = udid }
    }

    @objc(FakeHostSet) private final class FakeSet: NSObject {
        @objc var availableDevices: [NSObject]
        init(_ devices: [NSObject]) { availableDevices = devices }
    }

    @objc(FakeHostContext) private final class FakeContext: NSObject, @unchecked Sendable {
        let set: FakeSet
        init(_ set: FakeSet) { self.set = set }
        @objc(defaultDeviceSetWithError:) func defaultDeviceSet(_ error: NSErrorPointer) -> NSObject? { set }
    }

    /// A clock and a count of trips to CoreSimulator, which is what a read pays for.
    private final class Trips: @unchecked Sendable {
        var count = 0
        var time = 0.0
    }

    private func host(_ context: FakeContext?, _ trips: Trips) -> CoreSimulators {
        CoreSimulators(
            serviceContext: { trips.count += 1; return context },
            now: { trips.time })
    }

    private static let id = NSUUID()

    @Test func `should find a device once when it's read from again and again`() {
        let device = FakeDevice(Self.id)
        let trips = Trips()
        let host = host(FakeContext(FakeSet([device])), trips)

        #expect(host.resolveDevice(udid: Self.id.uuidString) === device)
        #expect(host.resolveDevice(udid: Self.id.uuidString) === device)
        #expect(host.resolveDevice(udid: Self.id.uuidString) === device)

        #expect(trips.count == 1)
    }

    @Test func `should look again once it has been a while`() {
        let device = FakeDevice(Self.id)
        let trips = Trips()
        let host = host(FakeContext(FakeSet([device])), trips)

        _ = host.resolveDevice(udid: Self.id.uuidString)
        trips.time += 60
        _ = host.resolveDevice(udid: Self.id.uuidString)

        #expect(trips.count == 2)
    }

    @Test func `should notice a deleted device once it has been a while`() {
        let set = FakeSet([FakeDevice(Self.id)])
        let trips = Trips()
        let host = host(FakeContext(set), trips)

        #expect(host.resolveDevice(udid: Self.id.uuidString) != nil)
        set.availableDevices = []
        trips.time += 60

        #expect(host.resolveDevice(udid: Self.id.uuidString) == nil)
    }

    @Test func `should keep looking for a device it hasn't found`() {
        let set = FakeSet([])
        let trips = Trips()
        let host = host(FakeContext(set), trips)

        #expect(host.resolveDevice(udid: Self.id.uuidString) == nil)
        let device = FakeDevice(Self.id)
        set.availableDevices = [device]

        #expect(host.resolveDevice(udid: Self.id.uuidString) === device)
    }

    @Test func `should remember each device on its own`() {
        let other = NSUUID()
        let first = FakeDevice(Self.id)
        let second = FakeDevice(other)
        let trips = Trips()
        let host = host(FakeContext(FakeSet([first, second])), trips)

        #expect(host.resolveDevice(udid: Self.id.uuidString) === first)
        #expect(host.resolveDevice(udid: other.uuidString) === second)
    }
}
