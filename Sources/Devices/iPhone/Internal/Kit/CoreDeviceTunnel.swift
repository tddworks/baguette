import Foundation

/// `Tunnel` through CoreDevice: the phone connected (`RemoteDevice.connect()`,
/// which keeps its tunnel up — unlike `devicectl`, whose tunnel drops some
/// fifteen seconds after it exits), then its end read from `devicectl list
/// devices` and this Mac's found on the same prefix. Reading the listing
/// rather than resolving the phone's `.coredevice.local` name avoids a
/// five-second mDNS timeout.
final class CoreDeviceTunnel: Tunnel, @unchecked Sendable {
    private let devicectl: Devicectl
    private let connect: @Sendable (UUID) throws -> Void
    private let interfaces: @Sendable () -> [String]

    init(devicectl: Devicectl = Devicectl(),
         connect: @escaping @Sendable (UUID) throws -> Void,
         interfaces: @escaping @Sendable () -> [String] = { HostNetwork.addresses() }) {
        self.devicectl = devicectl
        self.connect = connect
        self.interfaces = interfaces
    }

    func open(to phone: UUID) throws -> TunnelEnds {
        try connect(phone)
        guard let address = listedAddress(of: phone) else { throw TunnelError.down }
        guard let mac = TunnelAddress.local(facing: address, among: interfaces()) else { throw TunnelError.noMacEnd }
        return TunnelEnds(phone: address, mac: mac)
    }

    /// The phone's end of its tunnel, as devicectl lists it.
    private func listedAddress(of phone: UUID) -> String? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-tunnel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait(["list", "devices", "--quiet", "--json-output", file.path])) != nil,
              let data = try? Data(contentsOf: file),
              let listed = try? PhysicalPhone.list(fromDevicectlJSON: data).first(where: { $0.coreDeviceIdentifier == phone })
        else { return nil }
        return listed.tunnelAddress
    }
}
