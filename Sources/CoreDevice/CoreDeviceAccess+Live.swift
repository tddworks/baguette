import BaguetteDeviceFamilies
import Foundation

public extension CoreDeviceAccess {
    /// This Mac's CoreDevice, as Xcode installs it: a phone's tunnel through
    /// `RemoteDevice.connect()`, its touch through the Universal HID service,
    /// its screen through the media stream. On a Mac without CoreDevice it
    /// answers that it isn't there, and the iPhone family falls back to stills.
    static let live = CoreDeviceAccess(
        isAvailable: { CoreDeviceFramework.isAvailable },
        connect: { try CoreDeviceConnection.connect($0) },
        universalHID: CoreDeviceUniversalHID(),
        mediaStream: CoreDeviceMediaStream()
    )
}
