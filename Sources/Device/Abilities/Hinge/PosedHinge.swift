import Foundation

/// The angle a foldable's book is shown at.
///
/// The hinge's readings come back from the guest as it moves: every
/// 60 Hz sample in step on a quiet Mac, the same samples seconds late
/// on a loaded one. A sweep baguette plays itself is shown as commanded
/// (`HingeSweep`) instead; once it is delivered the book stands at the
/// target until the readings get there, then follows them again. A fold
/// made elsewhere — Device Hub, another process — is only ever seen
/// through the readings, so the book follows them as it always has.
public struct PosedHinge: Sendable {
    private enum Phase: Sendable {
        case following
        case playing(HingeSweep, since: TimeInterval)
        case standing(HingeSweep)
    }

    /// How close a reading must come to the target to show the sweep
    /// landed; the guest reports the target give or take its rounding.
    public static let landedTolerance: Double = 0.5

    private var phase = Phase.following
    private var reading: Double

    public init(reading: Double) {
        self.reading = reading
    }

    /// A reading while the book stands at the target is a late sample
    /// of the sweep as long as it keeps closing on it from within the
    /// sweep. One that lands, leaves the sweep or turns back is the
    /// hinge where it really is.
    public mutating func heard(_ angle: HingeAngle) {
        let previous = reading
        reading = angle.degrees
        guard case .standing(let sweep) = phase else { return }
        let gap = abs(angle.degrees - sweep.to)
        let span = min(sweep.from, sweep.to)...max(sweep.from, sweep.to)
        if gap <= Self.landedTolerance || !span.contains(angle.degrees) || gap > abs(previous - sweep.to) {
            phase = .following
        }
    }

    public mutating func began(_ sweep: HingeSweep, at time: TimeInterval) {
        phase = .playing(sweep, since: time)
    }

    /// A sweep the guest did not confirm leaves the readings as the
    /// only word on where the hinge is.
    public mutating func ended(_ delivery: PoseDelivery) {
        guard case .playing(let sweep, _) = phase else { return }
        let landed = abs(reading - sweep.to) <= Self.landedTolerance
        phase = delivery == .delivered && !landed ? .standing(sweep) : .following
    }

    public func degrees(at time: TimeInterval) -> Double {
        switch phase {
        case .following: reading
        case .playing(let sweep, let since): sweep.degrees(after: time - since)
        case .standing(let sweep): sweep.to
        }
    }

    /// Whether the book still moves on its own: a sweep short of its
    /// last sample.
    public func isMoving(at time: TimeInterval) -> Bool {
        guard case .playing(let sweep, let since) = phase else { return false }
        return !sweep.hasSettled(after: time - since)
    }
}
