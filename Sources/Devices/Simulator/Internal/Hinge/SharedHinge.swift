import BaguetteDevice
import Foundation

/// One monitor per device, shared by everyone who asks about its hinge.
///
/// A foldable's stream sockets each want the sweep, and every bind of
/// the phone plane wants the current angle. Giving each caller its own
/// `GuestHinge` put several monitors on one device at once and a
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
    private var last: (angle: HingeAngle, at: Date)?

    /// How long the last sample stays the answer after the watch
    /// stops. A pose change ends with the page reloading — socket and
    /// watch go down — and the new page's definition, mask and stream
    /// requests all ask within the next second or two. They must agree,
    /// and the sweep's final sample is the truth: the hinge does not
    /// move without Device Hub, and the new socket restarts the watch.
    static let gracePeriod: TimeInterval = 10

    private let motor: (any HingeMotor)?

    /// `presenting` asks the device which panel it lights (Core Device, in
    /// production); nil for a device that can't be asked, which leaves the
    /// angle to stand in. The delays are injectable so the schedule is
    /// unit-covered without a device.
    init(
        inner: any Hinge, motor: (any HingeMotor)? = nil, now: @escaping () -> Date = { Date() },
        presenting: (@Sendable () -> IntegratedPanel?)? = nil,
        settleDelays: [TimeInterval] = SharedHinge.settleDelays,
        pollInterval: TimeInterval = SharedHinge.pollInterval
    ) {
        self.inner = inner
        self.motor = motor
        self.now = now
        self.presenting = presenting
        self.settleDelays = settleDelays
        self.pollInterval = pollInterval
    }

    // MARK: - the panel the device presents on

    /// Asking Core Device takes about a third of a second: far too slow
    /// for every frame or touch. While the hinge is watched, its samples
    /// say when to ask — after it settles, at each of `settleDelays`,
    /// because SpringBoard swaps panels on its own schedule after the pose
    /// stops; every sample re-arms the series, so a sweep of any length
    /// costs at most that many reads — and a slow poll catches a swap no
    /// hinge motion announces (an app lighting the cover). With nobody
    /// watching, an answer stands for `presentingLifetime`. A failed read
    /// isn't news: the last answer stands.
    static let settleDelays: [TimeInterval] = [0.3, 1.0, 3.0]
    static let pollInterval: TimeInterval = 5
    static let presentingLifetime: TimeInterval = 2

    private let presenting: (@Sendable () -> IntegratedPanel?)?
    private let settleDelays: [TimeInterval]
    private let pollInterval: TimeInterval
    private let presentingQueue = DispatchQueue(label: "baguette.shared-hinge.presenting", qos: .utility)
    private var presented: (panel: IntegratedPanel?, at: Date)?
    private var settles: [DispatchWorkItem] = []
    private var poll: DispatchSourceTimer?

    func presentingPanel() -> IntegratedPanel? {
        guard presenting != nil else { return nil }
        let (cached, watched) = lock.withLock { (presented, innerWatch != nil) }
        if let cached, watched || now().timeIntervalSince(cached.at) < Self.presentingLifetime {
            return cached.panel
        }
        return readPresenting()
    }

    /// Asks the device once and keeps what it says; a failed answer keeps
    /// the last panel it named.
    @discardableResult
    private func readPresenting() -> IntegratedPanel? {
        guard let presenting else { return nil }
        let answer = presenting()
        return lock.withLock {
            let panel = answer ?? presented?.panel
            presented = (panel, now())
            return panel
        }
    }

    private func startFollowingPresentingPanel() {
        guard presenting != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: presentingQueue)
        timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.readPresenting() }
        lock.withLock { poll = timer }
        timer.resume()
    }

    private func stopFollowingPresentingPanel() {
        let (timer, pending) = lock.withLock { () -> (DispatchSourceTimer?, [DispatchWorkItem]) in
            defer { poll = nil; settles = [] }
            return (poll, settles)
        }
        timer?.cancel()
        pending.forEach { $0.cancel() }
    }

    /// A hinge sample: the fold is under way. Ask once it settles.
    private func hingeMoved() {
        guard presenting != nil else { return }
        let series = settleDelays.map { _ in DispatchWorkItem { [weak self] in self?.readPresenting() } }
        let stale = lock.withLock { () -> [DispatchWorkItem] in
            defer { settles = series }
            return settles
        }
        stale.forEach { $0.cancel() }
        for (delay, work) in zip(settleDelays, series) {
            presentingQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// A sweep starts where the hinge is — the angle last heard. With
    /// nothing heard (no `HingeControl`, or a silent guest) the
    /// hinge goes straight to the angle asked for rather than sweeping
    /// from a guessed start.
    ///
    /// Once the fold returns, delivered or not, a reading from before it
    /// is stale — clients rebind as soon as it does — so unless the last
    /// sample is the angle asked for (a watch heard the fold land), the
    /// next `angle()` asks the guest again.
    ///
    /// Sweep watchers hear the sweep as it goes to the motor and how it
    /// was delivered once it returns. Folds play one at a time, so each
    /// starts from where the last left the hinge and its watchers hear
    /// them in the order the guest plays them.
    func fold(to degrees: Double, over duration: TimeInterval) throws {
        guard let motor else { throw HingeError.toolMissing }
        folding.lock()
        defer { folding.unlock() }
        let from = angle()?.degrees ?? degrees
        defer {
            lock.lock()
            let landed = last.map { abs($0.angle.degrees - degrees) <= Self.landedTolerance } ?? false
            if !landed {
                last = nil
                silentSince = nil
            }
            lock.unlock()
        }
        announce(.began(HingeSweep(from: from, to: degrees, duration: duration)))
        do {
            try motor.fold(from: from, to: degrees, over: duration)
        } catch {
            announce(.ended(PoseDelivery(failure: error)))
            throw error
        }
        announce(.ended(.delivered))
    }

    private let folding = NSLock()
    private var sweepSubscribers: [UUID: @Sendable (HingeSweepEvent) -> Void] = [:]

    func watchSweeps(onSweep: @escaping @Sendable (HingeSweepEvent) -> Void) -> any HingeWatch {
        let id = UUID()
        lock.withLock { sweepSubscribers[id] = onSweep }
        return Subscription { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.sweepSubscribers[id] = nil }
        }
    }

    private func announce(_ event: HingeSweepEvent) {
        let targets = lock.withLock { Array(sweepSubscribers.values) }
        for target in targets { target(event) }
    }

    /// How close a sample must be to a fold's angle to show it landed;
    /// the guest reports the angle a sweep ends on, give or take its
    /// float rounding.
    static let landedTolerance: Double = 0.5

    // MARK: - registry

    private struct DeviceKey: Hashable {
        let deviceSetPath: String?
        let udid: String
    }
    nonisolated(unsafe) private static var registry: [DeviceKey: SharedHinge] = [:]
    private static let registryLock = NSLock()

    /// The shared hinge for `udid` in its device set, made on first use.
    static func forDevice(
        _ udid: String, deviceSetPath: String? = nil,
        make: () -> any Hinge, motor: @autoclosure () -> (any HingeMotor)? = nil,
        presenting: (@Sendable () -> IntegratedPanel?)? = nil
    ) -> SharedHinge {
        let key = DeviceKey(deviceSetPath: deviceSetPath, udid: udid)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let made = SharedHinge(inner: make(), motor: motor(), presenting: presenting)
        registry[key] = made
        return made
    }

    // MARK: - Hinge

    /// Serialises one-shot reads: a burst of callers with nothing
    /// cached spawns one monitor, and the rest take its sample. Two
    /// concurrent devicectl monitors on one device did not agree — the
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
        let startInner = innerWatch == nil
        // The stream is change-driven: its standing angle came once, at
        // start. A watcher joining a running monitor gets it now.
        let standing = startInner ? nil : last?.angle
        lock.unlock()
        if let standing { onAngle(standing) }
        if startInner {
            let started = inner.watch { [weak self] angle in self?.deliver(angle) }
            lock.lock()
            innerWatch = started
            lock.unlock()
            startFollowingPresentingPanel()
        }
        return Subscription { [weak self] in self?.remove(id) }
    }

    private func deliver(_ angle: HingeAngle) {
        lock.lock()
        last = (angle, now())
        let targets = Array(subscribers.values)
        lock.unlock()
        hingeMoved()
        for target in targets { target(angle) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers[id] = nil
        let stop = subscribers.isEmpty ? innerWatch : nil
        if stop != nil { innerWatch = nil }
        lock.unlock()
        stop?.cancel()
        if stop != nil { stopFollowingPresentingPanel() }
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
