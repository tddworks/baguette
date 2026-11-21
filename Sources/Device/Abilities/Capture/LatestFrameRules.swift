/// The rules for handing a screen's newest frame to one consumer — an encoder
/// or a renderer — without a queue and without a clock of its own (the
/// industry's "latest" or "conflate" backpressure):
///
/// - **Newest wins.** A frame waiting to start is replaced by a newer one,
///   never queued behind it.
/// - **One in flight.** The next frame starts only once the consumer is
///   `ready` again, so a slow consumer paces the source instead of falling
///   behind it.
/// - **A rate counted from fresh frames.** A fresh frame starts `1/fps` after
///   the last fresh one at the earliest (a hair early counts, as a recording's
///   `FrameCadence` counts it); a refresh never moves that mark.
/// - **Refreshes only when idle.** The last frame is sent again only when
///   nothing is in flight and no fresh frame waits — a still screen's
///   refresh never holds a change back.
///
/// Each call answers what to do now; `LatestFrame` does it.
public struct LatestFrameRules<Frame> {
    public enum Action {
        /// Hand this frame to the consumer.
        case start(Frame)
        /// A fresh frame waits for the rate: ask again (`due`) at this time.
        case wake(at: Double)
        case nothing
    }

    /// Fresh frames a second at most; 0 caps nothing.
    public var fps: Int
    private var waiting: Frame?
    private var last: Frame?
    private var inFlight = false
    private var lastFreshStart: Double?

    public init(fps: Int) {
        self.fps = fps
    }

    /// A fresh frame from the source.
    public mutating func offer(_ frame: Frame, at now: Double) -> Action {
        waiting = frame
        return next(at: now)
    }

    /// The consumer finished its frame and takes the next.
    public mutating func ready(at now: Double) -> Action {
        inFlight = false
        return next(at: now)
    }

    /// The time a `wake` asked for has come.
    public mutating func due(at now: Double) -> Action {
        next(at: now)
    }

    /// Send the last frame again, if the consumer has nothing else to do.
    public mutating func refresh() -> Action {
        guard !inFlight, waiting == nil, let last else { return .nothing }
        inFlight = true
        return .start(last)
    }

    /// Forget every frame; nothing is in flight any more.
    public mutating func clear() {
        waiting = nil
        last = nil
        inFlight = false
        lastFreshStart = nil
    }

    private mutating func next(at now: Double) -> Action {
        guard !inFlight, let frame = waiting else { return .nothing }
        if fps > 0, let lastFreshStart {
            let interval = 1.0 / Double(fps)
            let due = lastFreshStart + interval
            if now < due - interval * 0.05 { return .wake(at: due) }
        }
        waiting = nil
        last = frame
        inFlight = true
        lastFreshStart = now
        return .start(frame)
    }
}

extension LatestFrameRules.Action: Equatable where Frame: Equatable {}
