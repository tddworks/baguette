import Foundation

/// A physical phone's orientation, turned with `devicectl device
/// orientation set`. devicectl names the four poses as UIKit does, which
/// is what `DeviceOrientation` models.
struct DevicectlOrientation: Orientation {
    let udid: String
    let devicectl: Devicectl

    func set(_ orientation: DeviceOrientation) -> PoseDelivery {
        do {
            _ = try devicectl.runAndWait(
                ["device", "orientation", "set", "--device", udid, orientation.devicectlName])
            return .delivered
        } catch {
            return .rejected
        }
    }
}

private extension DeviceOrientation {
    var devicectlName: String {
        switch self {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft:      return "landscapeLeft"
        case .landscapeRight:     return "landscapeRight"
        }
    }
}
