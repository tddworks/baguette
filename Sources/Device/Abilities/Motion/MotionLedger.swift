import Foundation

/// The running totals behind `CMPedometer` — steps taken and metres
/// covered so far.
///
/// ## Why a ledger exists at all
///
/// A pedometer is cumulative. An app charting a day's steps must see them
/// climb across a walk → stop → walk sequence, so every change of intent
/// **banks** what the previous leg earned; the banked figure then rides
/// along inside the next `MotionIntent` as `stepsBefore` /
/// `distanceBefore`, and the dylib simply adds the leg it is currently
/// integrating on top. Without this, grabbing the joystick would reset the
/// day's step count.
///
/// The arithmetic lives here, in tested Swift, rather than in the dylib.
public struct MotionLedger: Equatable, Sendable {

    public let steps: Int
    public let metres: Double

    public static let empty = MotionLedger(steps: 0, metres: 0)

    /// Banks whatever `intent` earned between its start and `now`.
    ///
    /// Only **whole** steps count — half a step has not been taken — and
    /// distance is derived from those whole steps rather than from
    /// `speed × elapsed`, so an app can never read a distance that
    /// disagrees with the step count handed to it alongside.
    ///
    /// A leg that appears to have run backwards (clock skew, a
    /// `startedAt` in the future) banks nothing: a cumulative counter must
    /// never rewind.
    public func banking(_ intent: MotionIntent, at now: Double) -> MotionLedger {
        let elapsed = now - intent.startedAt
        guard elapsed > 0 else { return self }
        let profile = intent.profile
        guard profile.cadenceHz > 0, profile.strideMetres > 0 else { return self }
        let taken = Int((profile.cadenceHz * elapsed).rounded(.down))
        guard taken > 0 else { return self }
        return MotionLedger(steps: steps + taken,
                            metres: metres + Double(taken) * profile.strideMetres)
    }

    /// Rebuilds the running totals from an intent that is already published.
    ///
    /// A `MotionSession` keeps its ledger in memory, but the CLI is a fresh
    /// process every invocation and has none. The published intent already
    /// carries what came before it, so the file is the state: take its
    /// `stepsBefore` / `distanceBefore` and add the leg it has been running
    /// since. Without this, every `baguette motion set` published zeroes and
    /// an app's step count restarted on each command.
    public static func resuming(from published: MotionIntent?, at now: Double) -> MotionLedger {
        guard let published else { return .empty }
        return MotionLedger(steps: published.stepsBefore, metres: published.distanceBefore)
            .banking(published, at: now)
    }

    /// Opens the next leg carrying these totals forward.
    public func intent(kind: MotionKind, confidence: MotionConfidence, speed: Double,
                startedAt: Double) -> MotionIntent {
        MotionIntent(kind: kind, confidence: confidence, speed: speed,
                     startedAt: startedAt, stepsBefore: steps, distanceBefore: metres)
    }

    public init(steps: Int, metres: Double) {
        self.steps = steps
        self.metres = metres
    }
}
