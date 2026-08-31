import Foundation

/// The pose discipline between a phone's gyroscope and the 3D stage:
/// the first sample auto-zeroes (the twin faces front from wherever
/// the phone happens to be), applies are throttled to ~20/s, the
/// projected screen quad re-pushes a few times a second, and re-zero
/// captures the next sample as the new front. Pure state behind a
/// lock; the clock is injected so tests drive time deterministically.
final class TwinGyroState: @unchecked Sendable {
    struct Applied: Equatable {
        let rotation: DeviceRotation
        let zoom: Double
        let announce: Bool
        let pushQuad: Bool
    }

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var reference: Attitude?
    private var zoom: Double
    private var lastApply: TimeInterval?
    private var lastQuad: TimeInterval?
    private var announced = false

    private static let applyInterval: TimeInterval = 0.05
    private static let quadInterval: TimeInterval = 0.25
    private static let tiltBound = 80.0

    init(
        zoom: Double,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.zoom = zoom
        self.now = now
    }

    func rotation(for sample: AttitudeSample) -> Applied? {
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        if let last = lastApply, time - last < Self.applyInterval {
            return nil
        }
        lastApply = time
        let reference = self.reference ?? sample.attitude
        self.reference = reference

        let euler = sample.attitude.rezeroed(against: reference).eulerDegrees
        let rotation = DeviceRotation(
            x: max(-Self.tiltBound, min(Self.tiltBound, euler.x)),
            y: euler.y,
            z: euler.z
        )
        let announce = !announced
        announced = true
        let pushQuad = lastQuad.map { time - $0 >= Self.quadInterval } ?? true
        if pushQuad { lastQuad = time }
        return Applied(rotation: rotation, zoom: zoom, announce: announce, pushQuad: pushQuad)
    }

    /// The next sample becomes the new front.
    func rezero() {
        lock.lock()
        reference = nil
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
