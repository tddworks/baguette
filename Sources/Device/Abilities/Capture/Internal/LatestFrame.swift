import Foundation

/// A screen's newest frame, handed to one consumer at a time on `queue` by
/// `LatestFrameRules`: the consumer takes a frame and calls `ready` when it
/// can take the next — at once for one that finishes in place (a JPEG, a 3D
/// render), from its completion for one that finishes later (VideoToolbox).
/// A fresh frame never waits on a timer unless the frame rate asks it to.
///
/// With a `stallLimit`, a frame the consumer holds longer is given up on:
/// `onStall` runs on `queue`, then the next frame starts, and the held
/// frame's late `ready` changes nothing (docs/features/stream/design.md).
public final class LatestFrame<Frame>: @unchecked Sendable {
    public typealias Consumer = @Sendable (_ frame: Frame, _ ready: @escaping @Sendable () -> Void) -> Void

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let consumer: Consumer
    private let lock = NSLock()
    private var rules: LatestFrameRules<Frame>
    private var running = false
    /// Moves on with every frame handed over, and on every start and stop:
    /// a `ready` carrying an older one is stale and changes nothing.
    private var turn = 0
    private var timer: DispatchSourceTimer?
    private var timerAt: Double?
    private let stallLimit: Double?
    private let onStall: (@Sendable () -> Void)?
    private var stallTimer: DispatchSourceTimer?

    public init(
        queue: DispatchQueue, fps: Int, stallLimit: Double? = nil, onStall: (@Sendable () -> Void)? = nil,
        consumer: @escaping Consumer
    ) {
        self.queue = queue
        self.consumer = consumer
        self.stallLimit = stallLimit
        self.onStall = onStall
        rules = LatestFrameRules(fps: fps)
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start() {
        lock.withLock {
            rules.clear()
            turn += 1
            cancelTimer()
            cancelStallWatch()
            running = true
        }
    }

    /// A fresh frame from the source.
    public func offer(_ frame: Frame) {
        lock.withLock {
            guard running else { return }
            perform(rules.offer(frame, at: Self.now))
        }
    }

    /// Send the last frame again if the consumer has nothing else to do.
    public func refresh() {
        lock.withLock {
            guard running else { return }
            perform(rules.refresh())
        }
    }

    /// Fresh frames a second at most, from the next one on.
    public func apply(fps: Int) {
        lock.withLock {
            rules.fps = fps
            guard running, timer != nil else { return }
            cancelTimer()
            perform(rules.due(at: Self.now))
        }
    }

    /// Nothing starts after this returns. Unless `waitForDelivery` is false,
    /// a frame the consumer is being handed has been handed by then too.
    public func stop(waitForDelivery: Bool = true) {
        lock.withLock {
            running = false
            turn += 1
            cancelTimer()
            cancelStallWatch()
            rules.clear()
        }
        // A renderer may need its caller's main thread to finish; such owners
        // stop without waiting, and drop late results at their own gate.
        if waitForDelivery, DispatchQueue.getSpecific(key: queueKey) != true { queue.sync {} }
    }

    // MARK: - carrying out the rules (callers hold the lock)

    private func perform(_ action: LatestFrameRules<Frame>.Action) {
        switch action {
        case .start(let frame):
            turn += 1
            let mine = turn
            let consumer = self.consumer
            let ready: @Sendable () -> Void = { [weak self] in self?.ready(turn: mine) }
            watchForStall(turn: mine)
            queue.async { consumer(frame, ready) }
        case .wake(let at):
            arm(at: at)
        case .nothing:
            break
        }
    }

    private func ready(turn mine: Int) {
        lock.withLock {
            guard running, mine == turn else { return }
            cancelStallWatch()
            perform(rules.ready(at: Self.now))
        }
    }

    // MARK: - the stall watch (callers hold the lock)

    private func watchForStall(turn mine: Int) {
        cancelStallWatch()
        guard let stallLimit else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + stallLimit, leeway: .milliseconds(10))
        source.setEventHandler { [weak self] in self?.stalled(turn: mine) }
        stallTimer = source
        source.resume()
    }

    private func cancelStallWatch() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    /// On `queue`: the frame of `mine` is still held. Its turn ends here, so
    /// its late `ready` is stale; the owner hears first, then the next frame
    /// starts (it is queued behind this handler).
    private func stalled(turn mine: Int) {
        let gaveUp = lock.withLock { () -> Bool in
            guard running, mine == turn else { return false }
            turn += 1
            stallTimer = nil
            return true
        }
        guard gaveUp else { return }
        onStall?()
        lock.withLock {
            guard running else { return }
            perform(rules.ready(at: Self.now))
        }
    }

    private func arm(at deadline: Double) {
        if let timerAt, timerAt <= deadline { return }
        cancelTimer()
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let delay = max(0, deadline - Self.now)
        source.schedule(deadline: .now() + delay, leeway: .microseconds(250))
        source.setEventHandler { [weak self] in self?.due() }
        timer = source
        timerAt = deadline
        source.resume()
    }

    private func due() {
        lock.withLock {
            cancelTimer()
            guard running else { return }
            perform(rules.due(at: Self.now))
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerAt = nil
    }

    private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}
