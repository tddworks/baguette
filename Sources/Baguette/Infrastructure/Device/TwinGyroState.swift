import Foundation

/// The twin's gyro discipline, reduced to what the feature actually
/// is: sync the pose WHEN IT CHANGED. Each sample maps through
/// `Attitude.stagePose` — absolute against gravity, so a phone lying
/// on the desk renders a model lying on the stage — and is applied
/// only when it moved beyond the dead-band and the stream's frame
/// period has passed. A resting phone produces zero scene work and
/// therefore zero frames; there is no buffer, no free-running clock,
/// and no smoothing filter (CoreMotion's fused 60 Hz attitude is
/// already smooth).
///
/// The heading (yaw) is captured on the first sample and by
/// `rezero()` — the ONE axis `.xArbitraryZVertical` leaves arbitrary.
/// Pitch and roll are never calibrated away.
final class TwinGyroState: @unchecked Sendable {
    struct Applied: Equatable {
        let attitude: Attitude
        let zoom: Double
        let announce: Bool
        let pushQuad: Bool
    }

    private let lock = NSLock()
    private var heading: Double?
    private var zoom: Double
    private var lastApply: TimeInterval?
    private var lastQuad: TimeInterval?
    private var lastAttitude: Attitude?
    private var announced = false

    /// Poses closer than this (quaternion-dot tolerance, about a
    /// quarter degree) are the same pose — sensor micro-noise never
    /// renders. Compared against the last APPLIED pose so slow drift
    /// still accumulates across the band and eventually shows.
    private static let deadBand = 0.000002
    private static let quadInterval: TimeInterval = 0.25

    init(zoom: Double) {
        self.zoom = zoom
    }

    /// The pose to apply for this sample, or `nil` when nothing
    /// changed or the stream's frame period (`interval`) hasn't
    /// passed. Called on sample arrival — the samples are the clock.
    func pose(
        for sample: AttitudeSample,
        at hostNow: TimeInterval,
        interval: TimeInterval
    ) -> Applied? {
        lock.lock()
        defer { lock.unlock() }
        let heading = self.heading ?? sample.attitude.headingDegrees
        self.heading = heading

        if let lastApply, hostNow - lastApply < interval { return nil }

        let attitude = sample.attitude.stagePose(headingDegrees: heading)
        let changed = lastAttitude.map {
            !attitude.isApproximately($0, tolerance: Self.deadBand)
        } ?? true
        guard changed else { return nil }
        lastApply = hostNow
        lastAttitude = attitude

        let announce = !announced
        announced = true
        let pushQuad = lastQuad.map { hostNow - $0 >= Self.quadInterval } ?? true
        if pushQuad { lastQuad = hostNow }
        return Applied(attitude: attitude, zoom: zoom, announce: announce, pushQuad: pushQuad)
    }

    /// Capture the CURRENT heading as "facing the viewer". Pitch and
    /// roll stay absolute — re-zeroing a lying phone still shows a
    /// lying model, turned to face front.
    func rezero() {
        lock.lock()
        heading = nil
        lastAttitude = nil
        lastApply = nil
        lock.unlock()
    }

    /// A manual `set_3d_camera` changed the dolly — keep it under the
    /// gyro's rotation.
    func set(zoom: Double) {
        lock.lock()
        self.zoom = zoom
        lock.unlock()
    }
}
