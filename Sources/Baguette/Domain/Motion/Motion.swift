import Foundation
import Mockable

/// A booted simulator's simulated-motion surface. `publish` states what the
/// device is doing and makes apps able to read it; `clear` stops future app
/// launches from reading anything.
///
/// Unlike `Location` — which shells out to a supported `simctl` verb — there
/// is no platform support for this at all. `CMMotionActivityManager`,
/// `CMPedometer` and `CMMotionManager` all report unavailable in the
/// simulator, and locationd refuses a motion-activity subscription outright,
/// so the only way in is a dylib injected into the app under test. The
/// production impl is `SharedFileMotion` (Infrastructure); see
/// `docs/features/motion/README.md`.
@Mockable
protocol Motion: AnyObject, Sendable {
    /// State what the device is doing, and arm the dylib so apps launched
    /// from now on can read it.
    func publish(_ intent: MotionIntent) async throws

    /// Disarm the dylib. Apps launched afterwards see the platform's own
    /// answer again (motion unavailable). Apps **already running** still
    /// have the dylib loaded, so callers should park the device with a
    /// stationary `publish` first.
    func clear() async throws

    /// The intent currently published, or `nil` when nothing has been.
    ///
    /// Exists for callers that hold no session state — the CLI is a fresh
    /// process each invocation — so they can carry the pedometer's running
    /// totals forward instead of republishing zeroes. See
    /// `MotionLedger.resuming(from:at:)`.
    func published() -> MotionIntent?
}
