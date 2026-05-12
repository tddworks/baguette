import Foundation
import IOSurface
import ObjectiveC

/// Production `SurfacePusher` — dispatches `IOSurface` frames to a
/// SimulatorKit camera descriptor using ObjC runtime selectors.
///
/// Tries three selector variants in order of preference:
/// 1. `pushIOSurface:` — newer SimulatorKit builds.
/// 2. `sendIOSurface:` — older SimulatorKit builds.
/// 3. `setFramebufferSurface:` — generic fallback.
///
/// Throws `CameraError.injectionFailed` when none of the selectors
/// respond, so callers always know whether the frame was delivered.
final class SimulatorKitSurfacePusher: SurfacePusher, @unchecked Sendable {

    /// Push one `IOSurface` frame to the given camera descriptor.
    ///
    /// Walks the selector chain until one responds. This is the only
    /// ObjC interaction in the camera subsystem — the rest of the
    /// orchestration uses pure Swift.
    func push(_ surface: IOSurface, to descriptor: NSObject) throws {
        let pushSel = NSSelectorFromString("pushIOSurface:")
        if descriptor.responds(to: pushSel) {
            descriptor.perform(pushSel, with: surface)
            return
        }

        let sendSel = NSSelectorFromString("sendIOSurface:")
        if descriptor.responds(to: sendSel) {
            descriptor.perform(sendSel, with: surface)
            return
        }

        let setSel = NSSelectorFromString("setFramebufferSurface:")
        if descriptor.responds(to: setSel) {
            descriptor.perform(setSel, with: surface)
            return
        }

        throw CameraError.injectionFailed(
            reason: "no push/send IOSurface selector found on camera descriptor"
        )
    }
}
