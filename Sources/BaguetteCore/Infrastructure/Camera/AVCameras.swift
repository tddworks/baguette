import Foundation
import AVFoundation

/// `Cameras` backed by `AVCaptureDevice.DiscoverySession`. Integration-only:
/// one call to AVFoundation, then maps each `AVCaptureDevice` to a
/// `CameraDevice` value. Pure work lives in `CameraDevice`'s init;
/// this adapter is here purely for the AV plumbing.
final class AVCameras: Cameras, @unchecked Sendable {

    func available() async -> [CameraDevice] {
        // Include built-in (FaceTime), external (USB cameras), and
        // Continuity Camera (iPhone over the Wi-Fi-discovered link).
        // .external covers both USB webcams and Continuity Camera on
        // macOS 14+; older platforms degrade gracefully.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        let preferred = AVCaptureDevice.default(for: .video)
        return session.devices.map { dev in
            CameraDevice(
                uid: dev.uniqueID,
                name: dev.localizedName,
                isDefault: dev == preferred
            )
        }
    }
}
