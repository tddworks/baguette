import Foundation
import Mockable

/// A booted simulator's motion-shake surface. Delivering a shake posts
/// the `com.apple.UIKit.SimulatorShake` Darwin notification into the
/// guest's notify namespace, so UIKit's frontmost responder chain fires
/// `motionBegan(_:with:)` / `motionEnded(_:with:)` with
/// `UIEventSubtypeMotionShake` — the same signal Simulator.app's
/// "Device → Shake" menu synthesises.
///
/// Async because the underlying `simctl spawn` is a subprocess round
/// trip; throwing because the spawn can fail (host gone, device not
/// booted, `notifyutil` absent from the runtime). Prefer this handle
/// over reaching for `MotionShake` directly so callers get the same
/// ergonomics as `orientation()` / `location()`.
@Mockable
public protocol Shake: Sendable {
    /// Deliver a single shake to the booted simulator. Throws
    /// `ShakeError.simctlFailed` when the guest spawn exits non-zero.
    func shake() async throws
}
