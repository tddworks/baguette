/// A live stream keeps only the newest unencoded frame. Unlike a recording,
/// its final pending frame must still be delivered after the source goes quiet.
struct StreamFrameSchedule<Frame> {
    var fps: Int
    let repeating: Bool
    private var pending: Frame?
    private var latest: Frame?
    private var lastEmission: Double?

    init(fps: Int, repeating: Bool) {
        self.fps = fps
        self.repeating = repeating
    }

    mutating func offer(_ frame: Frame) { pending = frame }

    func deadline(at now: Double) -> Double? {
        guard pending != nil || (repeating && latest != nil) else { return nil }
        guard let lastEmission else { return now }
        return max(now, lastEmission + 1.0 / Double(max(1, fps)))
    }

    mutating func take(at now: Double) -> Frame? {
        guard let deadline = deadline(at: now), now >= deadline,
            let frame = pending ?? (repeating ? latest : nil)
        else { return nil }
        pending = nil
        latest = frame
        lastEmission = now
        return frame
    }

    mutating func clear() {
        pending = nil
        latest = nil
        lastEmission = nil
    }
}
