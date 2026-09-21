import Foundation

/// One monitor per device, shared by everyone who asks about its hinge.
///
/// A foldable's stream sockets each want the sweep, and every bind of
/// the phone plane wants the current angle. Giving each caller its own
/// `DevicectlHinge` put several monitors on one device at once and a
/// fresh spawn on every resolve — including inside `/hinge` polls
/// while a socket was already streaming samples. This runs a single
/// inner watch for as long as anyone subscribes, fans its samples out,
/// and answers `angle()` from the last sample while it runs; with no
/// watch running it falls back to a one-shot read.
///
/// All of the bookkeeping — subscriber fan-out, last sample, start on
/// first / stop on last — is here and unit-covered against `MockHinge`;
/// the inner hinge owns the process.
final class SharedHinge: Hinge, @unchecked Sendable {
    private let inner: any Hinge
    private let now: () -> Date
    private let lock = NSLock()
    private var subscribers: [UUID: @Sendable (HingeAngle) -> Void] = [:]
    private var innerWatch: (any HingeWatch)?
    /// Claimed under the lock by whoever starts the inner watch, before
    /// the (slow) start: a second subscriber arriving meanwhile must not
    /// start another — two devicectl monitors disagree, and the loser was
    /// never stopped.
    private var watching = false
    private var last: (angle: HingeAngle, at: Date)?

    /// How long the last sample stays the answer after the watch
    /// stops. A pose change ends with the page reloading — socket and
    /// watch go down — and the new page's definition, mask and stream
    /// requests all ask within the next second or two. They must agree,
    /// and the sweep's final sample is the truth: the hinge does not
    /// move without Device Hub, and the new socket restarts the watch.
    static let gracePeriod: TimeInterval = 10

    private let motor: (any HingeMotor)?

    init(inner: any Hinge, motor: (any HingeMotor)? = nil, now: @escaping () -> Date = { Date() }) {
        self.inner = inner
        self.motor = motor
        self.now = now
    }

    /// A sweep starts where the hinge is — the angle last heard, or shut
    /// when nothing has been heard, as the device boots.
    func fold(to degrees: Double, over duration: TimeInterval) throws {
        guard let motor else { throw HingeError.toolMissing }
        let from = angle()?.degrees ?? 0
        try motor.fold(from: from, to: degrees, over: duration)
    }

    // MARK: - registry

    nonisolated(unsafe) private static var registry: [String: SharedHinge] = [:]
    private static let registryLock = NSLock()

    /// The shared hinge for `udid`, made on first use.
    static func forDevice(
        _ udid: String, make: () -> any Hinge, motor: @autoclosure () -> (any HingeMotor)? = nil
    ) -> SharedHinge {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[udid] { return existing }
        let made = SharedHinge(inner: make(), motor: motor())
        registry[udid] = made
        return made
    }

    // MARK: - Hinge

    /// Serialises one-shot reads: a burst of callers with nothing
    /// cached spawns one monitor, and the rest take its sample. Two
    /// concurrent devicectl monitors on one device do not agree — the
    /// second reported 0° for a device at 130° — which is how a reload
    /// once bound the unfolded panel's stream under the cover's chrome.
    private let readLock = NSLock()

    /// How long a silent hinge is taken at its word. A read that heard
    /// nothing waited out its deadline; asking again at once would make
    /// every caller queue behind another such wait, and the server
    /// would stall for as long as the guest's motion stream is down.
    static let silencePeriod: TimeInterval = 3
    private var silentSince: Date?

    func angle() -> HingeAngle? {
        if let cached = fresh() { return cached }
        readLock.lock()
        defer { readLock.unlock() }
        if let cached = fresh() { return cached }
        lock.lock()
        let silent = silentSince.map { now().timeIntervalSince($0) < Self.silencePeriod } ?? false
        lock.unlock()
        if silent { return nil }
        guard let read = inner.angle() else {
            lock.lock()
            silentSince = now()
            lock.unlock()
            return nil
        }
        lock.lock()
        last = (read, now())
        silentSince = nil
        lock.unlock()
        return read
    }

    private func fresh() -> HingeAngle? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = last else { return nil }
        if innerWatch != nil || now().timeIntervalSince(cached.at) <= Self.gracePeriod {
            return cached.angle
        }
        return nil
    }

    func watch(onAngle: @escaping @Sendable (HingeAngle) -> Void) -> any HingeWatch {
        let id = UUID()
        lock.lock()
        subscribers[id] = onAngle
        let startInner = !watching
        watching = true
        // The stream is change-driven: its standing angle came once, at
        // start. A watcher joining a running monitor gets it now.
        let standing = startInner ? nil : last?.angle
        lock.unlock()
        if let standing { onAngle(standing) }
        if startInner {
            // The starter stays subscribed until this returns, so nobody
            // can empty the subscribers before the watch is recorded.
            let started = inner.watch { [weak self] angle in self?.deliver(angle) }
            lock.lock()
            innerWatch = started
            lock.unlock()
        }
        return Subscription { [weak self] in self?.remove(id) }
    }

    private func deliver(_ angle: HingeAngle) {
        lock.lock()
        last = (angle, now())
        let targets = Array(subscribers.values)
        lock.unlock()
        for target in targets { target(angle) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers[id] = nil
        let stop = subscribers.isEmpty ? innerWatch : nil
        if subscribers.isEmpty { innerWatch = nil; watching = false }
        lock.unlock()
        stop?.cancel()
    }

    private final class Subscription: HingeWatch, @unchecked Sendable {
        private let lock = NSLock()
        private var onCancel: (() -> Void)?
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() {
            lock.lock()
            let run = onCancel
            onCancel = nil
            lock.unlock()
            run?()
        }
    }
}
