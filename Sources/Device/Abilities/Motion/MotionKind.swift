import Foundation

/// What the device is doing, as an app reads it back from
/// `CMMotionActivity` — the classification behind `walking` / `running` /
/// `cycling` / `automotive` / `stationary`.
///
/// ## Why this is derived from speed
///
/// The simulator has no motion coprocessor, so nothing classifies motion
/// for us: `CMMotionActivityManager.isActivityAvailable()` is `false` and
/// locationd refuses the subscription outright (see
/// `docs/features/motion/README.md`). baguette supplies the classification
/// itself, and the only honest input it has is the speed the device is
/// being driven at by a walk or a route.
///
/// The thresholds are pinned to the speed presets the browser's Walk mode
/// already offers — `Walk 1.4 · Run 3.5 · Cycle 6 · Drive 13.4 ·
/// Highway 29` (m/s) — so the label a user picked in the UI is the label
/// the app under test observes. They're band *midpoints*, not the preset
/// values themselves, so a hand-typed speed near a preset still lands on
/// the intended side.
public enum MotionKind: String, Equatable, Sendable, CaseIterable {
    case unknown
    case stationary
    case walking
    case running
    case cycling
    case automotive

    /// Below this the device is standing still. Dead-reckoning jitter
    /// around a pinned point stays under it, so releasing the joystick
    /// reads as `stationary` rather than a very slow walk.
    public static let stationaryCeiling = 0.2

    /// Band ceilings, in metres per second, each sitting between two
    /// neighbouring presets.
    private static let walkingCeiling = 2.2      // between Walk 1.4 and Run 3.5
    private static let runningCeiling = 4.5      // between Run 3.5 and Cycle 6
    private static let cyclingCeiling = 8.5      // between Cycle 6 and Drive 13.4

    /// The private `CLMotionActivity.type` value that makes
    /// `CMMotionActivity` report this kind.
    ///
    /// **Measured, not documented.** The field was swept 0…9 inside a
    /// booted iOS 26.5 / 27.0 runtime and the public flags read back. The
    /// enum is not dense — `2` duplicates stationary, and `3` / `7` / `9`
    /// read as no flags at all — so only these six values are trusted.
    /// Resolving it here means the injected dylib copies a number it was
    /// handed instead of carrying a mapping of its own.
    public var coreMotionType: Int32 {
        switch self {
        case .unknown: return 0
        case .stationary: return 1
        case .walking: return 4
        case .automotive: return 5
        case .cycling: return 6
        case .running: return 8
        }
    }

    /// Classifies a speed in metres per second.
    ///
    /// A **negative** speed is CoreLocation's "unknown", not a standstill —
    /// `simctl location set` pins a point and reports `speed,-1 course,-1`.
    /// Collapsing that into `stationary` would assert something the
    /// platform never said, so it maps to `unknown`.
    public static func from(speed: Double) -> MotionKind {
        guard speed >= 0 else { return .unknown }
        switch speed {
        case ..<stationaryCeiling: return .stationary
        case ..<walkingCeiling: return .walking
        case ..<runningCeiling: return .running
        case ..<cyclingCeiling: return .cycling
        default: return .automotive
        }
    }
}
