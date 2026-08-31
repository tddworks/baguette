import Foundation

/// The twin's gyro discipline — the synthesis the feature settled on
/// after trying simpler shapes:
///
/// - **Absolute against gravity**: every sample maps through
///   `Attitude.stagePose`, so a phone lying on the desk renders a
///   model lying on the stage. Only the compass-arbitrary heading is
///   calibrated (first sample / `rezero()`); pitch and roll never are.
/// - **A metronome, not arrival-driven applies**: pose travels inside
///   server-rendered VIDEO, and video is only smooth when its frames
///   sample motion at REGULAR times. ReplayKit's mirror frames arrive
///   irregularly (it emits on screen change), so the 3D socket ticks
///   at the stream's fps and asks `pose(at:)` — the equivalent of the
///   client-side render loop PhoneTwin gets for free.
/// - **Snapshot interpolation with a monotonic clock**: ticks replay
///   the timestamped trajectory `delay` behind the newest sample,
///   slerping between the bracketing samples — even samples of the
///   true motion, immune to Wi-Fi jitter up to the budget. The
///   sender→host offset is the max ever seen, so a late arrival can
///   never rebase playback backwards (the bug that once made
///   interpolation feel broken).
/// - **Emit only on change**: a tick whose pose sits inside the
///   dead-band returns `nil` — a resting phone costs zero renders and
///   zero frames.
final class TwinGyroState: @unchecked Sendable {
    struct Applied: Equatable {
        let attitude: Attitude
        let zoom: Double
        let pushQuad: Bool
    }

    private struct Entry {
        let sender: Double
        let attitude: Attitude
    }

    private let lock = NSLock()
    private var heading: Double?
    private var entries: [Entry] = []
    private var zoom: Double
    private var senderOffset: Double?
    private var lastPlayback: Double?
    private var lastAttitude: Attitude?
    private var lastQuad: TimeInterval?

    /// The delay budget floor — three clean sample periods. The LIVE
    /// budget adapts upward to measured arrival jitter (an extension
    /// under load has been seen stalling 200+ ms): worst recent gap
    /// × 1.5, decaying slowly, capped so lag stays bounded. Sized by
    /// measurement, never by feel.
    private static let delayFloor: TimeInterval = 0.05
    private static let delayCap: TimeInterval = 0.3
    private var lastArrival: TimeInterval?
    private var gapEstimate: TimeInterval = 0.017
    private static let quadInterval: TimeInterval = 0.25
    private static let capacity = 120
    /// Poses closer than this (quaternion-dot tolerance, about a
    /// quarter degree) are the same pose — sensor micro-noise never
    /// renders.
    private static let deadBand = 0.000002

    init(zoom: Double) {
        self.zoom = zoom
    }

    /// Feed one sample. Returns `true` exactly once — the first sample
    /// ever — so the caller can announce the gyro going live.
    func add(_ sample: AttitudeSample, arrivedAt host: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = entries.isEmpty && heading == nil
        let heading = self.heading ?? sample.attitude.headingDegrees
        self.heading = heading
        entries.append(Entry(
            sender: sample.timestamp,
            attitude: sample.attitude.stagePose(headingDegrees: heading)
        ))
        let offset = sample.timestamp - host
        senderOffset = max(senderOffset ?? offset, offset)
        if let lastArrival {
            gapEstimate = max(host - lastArrival, gapEstimate * 0.98)
        }
        lastArrival = host
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        return first
    }

    /// The pose the render clock should show at `hostNow`, or `nil`
    /// when it hasn't moved past the dead-band — nothing to render.
    func pose(at hostNow: TimeInterval) -> Applied? {
        lock.lock()
        defer { lock.unlock() }
        guard let newest = entries.last, let senderOffset else { return nil }

        let delay = min(max(Self.delayFloor, gapEstimate * 1.5), Self.delayCap)
        var playback = hostNow + senderOffset - delay
        playback = min(max(playback, entries[0].sender), newest.sender)
        if let lastPlayback { playback = max(playback, min(lastPlayback, newest.sender)) }
        lastPlayback = playback

        var attitude = newest.attitude
        if entries.count > 1 {
            var index = entries.count - 1
            while index > 0 && entries[index - 1].sender > playback {
                index -= 1
            }
            if index > 0 {
                let a = entries[index - 1]
                let b = entries[index]
                let span = b.sender - a.sender
                let fraction = span > 0 ? (playback - a.sender) / span : 1
                attitude = a.attitude.slerped(toward: b.attitude, fraction: fraction)
            } else {
                attitude = entries[0].attitude
            }
        }

        let changed = lastAttitude.map {
            !attitude.isApproximately($0, tolerance: Self.deadBand)
        } ?? true
        guard changed else { return nil }
        lastAttitude = attitude

        let pushQuad = lastQuad.map { hostNow - $0 >= Self.quadInterval } ?? true
        if pushQuad { lastQuad = hostNow }
        return Applied(attitude: attitude, zoom: zoom, pushQuad: pushQuad)
    }

    /// Capture the CURRENT heading as "facing the viewer". Pitch and
    /// roll stay absolute — re-zeroing a lying phone still shows a
    /// lying model, turned to face front.
    func rezero() {
        lock.lock()
        heading = nil
        entries.removeAll()
        lastPlayback = nil
        lastAttitude = nil
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
