import Foundation

/// The phone connected through CoreDevice: `RemoteDevice.connect()`, which
/// brings its tunnel up and keeps it. Integration-only; what follows is
/// `CoreDeviceTunnel`'s.
enum CoreDeviceConnection {
    static func connect(_ phone: UUID) throws {
        #if COREDEVICE
        guard let device = CoreDeviceFramework.device(phone) else { throw CoreDeviceError.unavailable }
        try device.connect()
        #else
        throw CoreDeviceError.unavailable
        #endif
    }
}
