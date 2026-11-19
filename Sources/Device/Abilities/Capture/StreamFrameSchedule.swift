/// A live stream keeps only the newest unencoded frame. Unlike a recording,
/// its final pending frame must still be delivered after the source goes quiet.
public struct StreamFrameSchedule<Frame> {
    public var fps: Int
    public let repeating: Bool
    private var pending: Frame?
    private var latest: Frame?
    private var lastEmission: Double?

    public init(fps: Int, repeating: Bool) {
        self.fps = fps
        self.repeating = repeating
    }

    public mutating func offer(_ frame: Frame) { pending = frame }

    public func deadline(at now: Double) -> Double? {
        guard pending != nil || (repeating && latest != nil) else { return nil }
        guard let lastEmission else { return now }
        return max(now, lastEmission + 1.0 / Double(max(1, fps)))
    }

    public mutating func take(at now: Double) -> Frame? {
        guard let deadline = deadline(at: now), now >= deadline,
            let frame = pending ?? (repeating ? latest : nil)
        else { return nil }
        pending = nil
        latest = frame
        lastEmission = now
        return frame
    }

    public mutating func clear() {
        pending = nil
        latest = nil
        lastEmission = nil
    }
}
