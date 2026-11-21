/// When a still screen's last frame is sent again (a refresh frame): every
/// `1/fps`, on a beat anchored to the clock. The next refresh is due one
/// interval after the previous one was *due*, never after it ran, so a refresh
/// that runs late doesn't push every later one back; a beat that was missed
/// altogether is skipped, not caught up.
///
/// Not the simulator screen's idle floor (`ScreenIdleFloor`): that *captures*
/// a fresh surface when SimulatorKit stops calling back (CarPlay's home screen,
/// a quiet lock screen), so content isn't missed; this *re-sends* the frame
/// already encoded, so a decoder keeps moving on a still picture.
public struct RefreshCadence: Equatable, Sendable {
    public var fps: Int {
        didSet { if fps != oldValue { due = nil } }
    }
    private var due: Double?

    public init(fps: Int) {
        self.fps = fps
    }

    /// When the next refresh is due, from `now`.
    public mutating func next(at now: Double) -> Double {
        let interval = 1.0 / Double(max(1, fps))
        guard var next = due.map({ $0 + interval }) else {
            due = now + interval
            return now + interval
        }
        if next <= now { next += (((now - next) / interval).rounded(.down) + 1) * interval }
        due = next
        return next
    }
}
