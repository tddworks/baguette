import Foundation
import Mockable

/// A simulator's hinge — the fold of iPhone Duo.
///
/// The angle is the runtime's own reading (see `HingeAngle`), and it
/// decides which of a foldable's panels is lit, so the phone plane binds
/// its framebuffer and digitizer through it. Single-panel devices have
/// no hinge and never ask.
///
/// Read through `GuestHinge`; driven through `HingeMotor`, which
/// runs `HingeControl` in the guest to send the pose events Device Hub
/// sends. `SharedHinge` composes the two.
@Mockable
public protocol Hinge: Sendable {
    /// The current angle, or `nil` when the device has no hinge or the
    /// reading did not arrive. Callers take `nil` as "as booted": folded.
    func angle() -> HingeAngle?

    /// Every sample the runtime reports, in order, until the watch is
    /// cancelled. Device Hub animates a pose change as a 0.5–0.85 s
    /// sweep at 60 Hz (0° closed, 130° its open pose, 180° flat), and
    /// this is how a page draws the fold at the angle the device is
    /// actually at. A device without a hinge delivers nothing.
    func watch(onAngle: @escaping @Sendable (HingeAngle) -> Void) -> any HingeWatch

    /// Every sweep baguette plays on this hinge (`fold`), as it begins and
    /// as it ends, until the watch is cancelled. A 3D book shows such a
    /// sweep as commanded (`PosedHinge`): the samples `watch` delivers
    /// can come back seconds late on a loaded host. Folds made elsewhere
    /// are heard only through `watch`.
    func watchSweeps(onSweep: @escaping @Sendable (HingeSweepEvent) -> Void) -> any HingeWatch

    /// Move the hinge to `degrees` over `duration` seconds — Device Hub's
    /// pose picker, from baguette. Throws when the device cannot be
    /// driven (no `HingeControl`, or the guest refused).
    func fold(to degrees: Double, over duration: TimeInterval) throws
}

public extension Hinge {
    /// The panel this hinge lights: no reading means as booted, folded,
    /// so the cover. The one place that rule lives.
    var litPanel: IntegratedPanel { angle()?.litPanel ?? .primary }
}

/// A running watch on a hinge; `cancel` stops the samples.
@Mockable
public protocol HingeWatch: Sendable {
    func cancel()
}
