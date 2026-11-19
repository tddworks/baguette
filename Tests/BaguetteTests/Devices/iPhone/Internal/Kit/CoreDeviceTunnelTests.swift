import Foundation
import Testing
@testable import Baguette

/// The phone's tunnel through CoreDevice, with the connect call, devicectl
/// and this Mac's addresses stood in for: when it is brought up, and where
/// its two ends are.
@Suite("CoreDeviceTunnel")
struct CoreDeviceTunnelTests {
    private struct Refused: Error, Equatable {}

    /// What happened, in order.
    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var _connected: [UUID] = []
        private var _listedBeforeConnecting = false
        var connected: [UUID] { lock.withLock { _connected } }
        var listedBeforeConnecting: Bool { lock.withLock { _listedBeforeConnecting } }
        func connect(_ phone: UUID, listedSoFar: Int) {
            lock.withLock {
                _connected.append(phone)
                if listedSoFar > 0 { _listedBeforeConnecting = true }
            }
        }
    }

    private func tunnel(
        listing: String? = PhoneJSON.tunnel,
        interfaces: [String] = [PhoneJSON.mac, "::1"],
        refusing: Bool = false
    ) -> (CoreDeviceTunnel, FakeDevicectl, Steps) {
        let devicectl = PhoneJSON.devicectl(listings: [PhoneJSON.listing(tunnelAddress: listing)])
        let steps = Steps()
        let tunnel = CoreDeviceTunnel(
            devicectl: Devicectl(makeSubprocess: devicectl.make),
            connect: { phone in
                steps.connect(phone, listedSoFar: devicectl.arguments.count)
                if refusing { throw Refused() }
            },
            interfaces: { interfaces })
        return (tunnel, devicectl, steps)
    }

    @Test func `should answer both ends of the phone's tunnel`() throws {
        let (tunnel, _, _) = tunnel()

        let ends = try tunnel.open(to: PhoneJSON.identifier)

        #expect(ends == TunnelEnds(phone: PhoneJSON.tunnel, mac: PhoneJSON.mac))
    }

    @Test func `should connect the phone before asking where its tunnel is`() throws {
        let (tunnel, devicectl, steps) = tunnel()

        _ = try tunnel.open(to: PhoneJSON.identifier)

        #expect(steps.connected == [PhoneJSON.identifier])
        #expect(!steps.listedBeforeConnecting)
        #expect(devicectl.arguments.first?.prefix(3) == ["devicectl", "list", "devices"])
    }

    @Test func `should fail when CoreDevice can't connect the phone`() {
        let (tunnel, devicectl, _) = tunnel(refusing: true)

        #expect(throws: Refused()) { try tunnel.open(to: PhoneJSON.identifier) }
        #expect(devicectl.arguments.isEmpty)
    }

    @Test func `should fail when the phone's tunnel is still down after connecting`() {
        let (tunnel, _, _) = tunnel(listing: nil)

        #expect(throws: TunnelError.down) { try tunnel.open(to: PhoneJSON.identifier) }
    }

    @Test func `should fail when this Mac has no end on the phone's tunnel`() {
        let (tunnel, _, _) = tunnel(interfaces: ["::1"])

        #expect(throws: TunnelError.noMacEnd) { try tunnel.open(to: PhoneJSON.identifier) }
    }
}
