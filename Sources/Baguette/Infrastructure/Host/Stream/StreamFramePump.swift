import Foundation

/// At most one queued delivery and one latest frame, even if encoding is slower
/// than capture. The lock protects scheduling; delivery runs on the encode queue.
final class StreamFramePump<Frame>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let deliver: @Sendable (Frame) -> Void
    private let lock = NSLock()
    private var schedule: StreamFrameSchedule<Frame>
    private var task: DispatchWorkItem?
    private var generation = 0
    private var running = false

    init(queue: DispatchQueue, fps: Int, repeating: Bool, deliver: @escaping @Sendable (Frame) -> Void) {
        self.queue = queue
        self.deliver = deliver
        schedule = StreamFrameSchedule(fps: fps, repeating: repeating)
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() {
        lock.withLock {
            schedule.clear()
            running = true
        }
    }

    func offer(_ frame: Frame) {
        lock.withLock {
            guard running else { return }
            schedule.offer(frame)
            arm()
        }
    }

    func apply(fps: Int) {
        lock.withLock {
            schedule.fps = fps
            task?.cancel()
            task = nil
            generation += 1
            arm()
        }
    }

    func stop(waitForDelivery: Bool = true) {
        lock.withLock {
            running = false
            generation += 1
            task?.cancel()
            task = nil
            schedule.clear()
        }
        // Rendering may synchronously need the caller's main thread. Such owners
        // cancel without waiting and suppress late results at their delivery gate.
        if waitForDelivery, DispatchQueue.getSpecific(key: queueKey) != true { queue.sync {} }
    }

    /// Caller holds lock. Relative deadlines use monotonic uptime.
    private func arm() {
        guard running, task == nil, let deadline = schedule.deadline(at: Self.now) else { return }
        let current = generation
        let work = DispatchWorkItem { [weak self] in self?.fire(generation: current) }
        task = work
        queue.asyncAfter(deadline: .init(uptimeNanoseconds: UInt64(ceil(deadline * 1_000_000_000))), execute: work)
    }

    private func fire(generation current: Int) {
        let frame: Frame? = lock.withLock {
            guard running, current == generation else { return nil }
            task = nil
            return schedule.take(at: Self.now)
        }
        if let frame { deliver(frame) }
        lock.withLock { arm() }
    }

    private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}
