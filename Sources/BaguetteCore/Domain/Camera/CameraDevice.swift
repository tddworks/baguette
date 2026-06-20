import Foundation

/// One camera the host can capture from. Identity is `uid` —
/// `AVCaptureDevice.uniqueID` in the production adapter. `name` is the
/// human-friendly label ("FaceTime HD Camera"), `isDefault` is the
/// system-preferred camera (drives the picker's initial selection).
struct CameraDevice: Equatable, Sendable, Hashable {
    let uid: String
    let name: String
    let isDefault: Bool

    /// Shape pushed to the browser as `camera_devices.devices[*]`.
    /// Returns `[String: Any]` because that's the contract NIO's
    /// JSONSerialization expects from the WS path.
    var wireDictionary: [String: Any] {
        [
            "uid": uid,
            "name": name,
            "isDefault": isDefault,
        ]
    }
}
