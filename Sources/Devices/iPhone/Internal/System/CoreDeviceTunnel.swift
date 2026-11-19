import Foundation

/// `Tunnel` through CoreDevice: `RemoteDevice.connect()`, which brings the
/// phone's tunnel up and keeps it — unlike `devicectl`, whose tunnel drops
/// some fifteen seconds after it exits. Integration-only.
struct CoreDeviceTunnel: Tunnel {
    func open(to phone: UUID) throws {
        #if COREDEVICE
        guard let device = CoreDeviceFramework.device(phone) else { throw CoreDeviceError.unavailable }
        try device.connect()
        #else
        throw CoreDeviceError.unavailable
        #endif
    }
}
