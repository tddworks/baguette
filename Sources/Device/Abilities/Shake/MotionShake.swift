import Foundation

/// The UIKit motion-shake signal delivered to a booted simulator.
///
/// Knows the private Darwin notification name UIKit's shake detection
/// listens for and the `xcrun simctl spawn` argv that posts it into a
/// booted simulator's *guest* notify namespace. A `notify_post` from
/// the host would land in the host's notifyd, which the iOS guest never
/// observes — so the notification is posted by `notifyutil` spawned
/// *inside* the simulator runtime via `simctl spawn <udid>`, where its
/// `notify_post` reaches the guest's notifyd and UIKit's frontmost
/// responder chain fires `motionBegan(_:with:)` / `motionEnded(_:with:)`
/// with `UIEventSubtypeMotionShake`. This is the same signal
/// Simulator.app's "Device → Shake" menu ultimately synthesises.
public struct MotionShake: Equatable, Sendable {
    public init() {}

    /// Darwin notification UIKit's shake detection observes. Widely
    /// used from inside a running app (`notify_post` in UI tests); we
    /// post it from a guest-spawned `notifyutil` instead so no code has
    /// to run inside the target app.
    public static let notificationName = "com.apple.UIKit.SimulatorShake"

    /// `xcrun simctl` arguments that post the shake notification inside
    /// the guest. `notifyutil -p <name>` fires a one-shot Darwin
    /// notification; running it under `simctl spawn <udid>` lands it in
    /// the simulator's notify namespace rather than the host Mac's.
    /// `deviceSetPath` names a custom device set the simulator lives in;
    /// simctl only looks in the default set without it.
    public func simctlArguments(udid: String, deviceSetPath: String? = nil) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["spawn", udid, "notifyutil", "-p", Self.notificationName]
    }
}

/// Failure mode surfaced by the shake dispatch — the guest `simctl
/// spawn` exited non-zero (host gone, device not booted, notifyutil
/// missing from the runtime).
public enum ShakeError: Error, Equatable {
    case simctlFailed(status: Int32)
}
