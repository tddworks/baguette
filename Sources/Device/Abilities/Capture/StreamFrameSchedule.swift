/// A live stream keeps only the newest unencoded frame. Unlike a recording,
/// its final pending frame must still be delivered after the source goes quiet.
///
/// A fresh frame is held only to keep fresh frames `1/fps` apart; a repeat of a
/// still screen never holds one back, so a change (a tap's answer) is encoded as
/// soon as it arrives rather than one interval after the last repeat. Repeats
/// follow the last emission of either kind.
public struct StreamFrameSchedule<Frame> {
    public var fps: Int
    public let repeating: Bool
    private var pending: Frame?
    private var latest: Frame?
    private var lastEmission: Double?
    private var lastFresh: Double?

    public init(fps: Int, repeating: Bool) {
        self.fps = fps
        self.repeating = repeating
    }

    public mutating func offer(_ frame: Frame) { pending = frame }

    public func deadline(at now: Double) -> Double? {
        let interval = 1.0 / Double(max(1, fps))
        if pending != nil {
            guard let lastFresh else { return now }
            return max(now, lastFresh + interval)
        }
        guard repeating, latest != nil else { return nil }
        guard let lastEmission else { return now }
        return max(now, lastEmission + interval)
    }

    public mutating func take(at now: Double) -> Frame? {
        guard let deadline = deadline(at: now), now >= deadline,
            let frame = pending ?? (repeating ? latest : nil)
        else { return nil }
        if pending != nil { lastFresh = now }
        pending = nil
        latest = frame
        lastEmission = now
        return frame
    }

    public mutating func clear() {
        pending = nil
        latest = nil
        lastEmission = nil
        lastFresh = nil
    }
}
