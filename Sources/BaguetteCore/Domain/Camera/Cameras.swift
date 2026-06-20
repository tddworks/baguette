import Foundation
import Mockable

/// Aggregate-style enumeration of the cameras the host can capture
/// from. The production adapter (`AVCameras`) wraps
/// `AVCaptureDevice.DiscoverySession`. The plural-collection-noun
/// is the carve-out from the no-`Repository` rule: this protocol's
/// role is genuinely "load the set of `CameraDevice` aggregates."
@Mockable
protocol Cameras: AnyObject, Sendable {
    func available() async -> [CameraDevice]
}
