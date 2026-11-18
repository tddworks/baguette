import Foundation
import IOSurface

/// A foldable's two screens and hinge, composed through one persistent
/// 3D device scene.
///
/// Frames from either panel and hinge poses all funnel into one
/// serialized composition of the latest state — the latest frame of
/// each panel on its screen, the book posed at the latest angle. As in
/// `RenderedScreen`, at most one composition is pending, so a slow model
/// drops stale work instead of queueing it.
///
/// The book is posed where `PosedHinge` has it: at the hinge's readings,
/// except while baguette plays a sweep, whose frames it steps through at
/// 60 Hz as commanded however late the readings come back.
final class RenderedFoldable: DeviceFrames, @unchecked Sendable {
    private let unfolded: any Screen
    private let cover: any Screen
    private let hinge: any Hinge
    private let scene: any DeviceScene
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.baguette.rendered-foldable",
        qos: .userInteractive
    )
    private let fps: Int?
    private lazy var pump = fps.map { rate in
        StreamFramePump<Void>(queue: queue, fps: rate, repeating: false) { [weak self] in self?.render() }
    }
    private var delivery: (@Sendable (IOSurface) -> Void)?
    private var watch: (any HingeWatch)?
    private var sweeps: (any HingeWatch)?
    private var ticker: (any DispatchSourceTimer)?
    private var frameDelivery: (@Sendable (Result<DeviceFrame, any Error>) -> Void)?
    private var isRendering = false
    private var pending = false
    private var latest = FoldableScreens(unfolded: nil, cover: nil)
    private var isStopped = true
    /// A scene starts flat. Nothing is composed until the book has been
    /// posed, or the first frame would show it open when shut.
    private var isPosed = false
    /// The angle the book is posed at (shut until the hinge speaks).
    private var hingeDegrees: Double = 0
    private var posed = PosedHinge(reading: 0)
    /// One pose at a time: a reading and a sweep's frame must reach the
    /// scene in the order they were decided.
    private let posing = NSLock()

    /// The pose the book is shown at.
    var pose: FoldablePose {
        lock.withLock { FoldablePose(hingeDegrees: hingeDegrees) }
    }

    private let onPose: @Sendable (FoldablePose) -> Void
    /// Monotonic seconds; a sweep's frames are timed by it.
    private let now: @Sendable () -> TimeInterval

    /// `onPose` runs after each new pose — a hinge sample, or a frame of
    /// a sweep baguette plays — with the pose it now stands at, so a
    /// listener never needs to hold the book to read it (that cycle kept
    /// a closed stream's scene alive).
    init(
        unfolded: any Screen, cover: any Screen, hinge: any Hinge, scene: any DeviceScene,
        fps: Int? = nil, onPose: @escaping @Sendable (FoldablePose) -> Void = { _ in },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.unfolded = unfolded
        self.cover = cover
        self.hinge = hinge
        self.scene = scene
        self.fps = fps
        self.onPose = onPose
        self.now = now
    }

    func startFrames(onFrame: @escaping @Sendable (Result<DeviceFrame, any Error>) -> Void) throws {
        lock.withLock { frameDelivery = onFrame }
        try start { _ in }
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock {
            delivery = onFrame
            isStopped = false
            isPosed = false
        }
        pump?.start()
        // A silent hinge (the guest's motion stream can drop) still
        // gets a book: shut, as the device boots, until it speaks.
        let standing = hinge.angle()?.degrees ?? 0
        lock.withLock {
            hingeDegrees = standing
            posed = PosedHinge(reading: standing)
            isPosed = true
        }
        scene.update(hingeDegrees: standing)
        do {
            try unfolded.start { [weak self] surface in
                self?.take { FoldableScreens(unfolded: surface, cover: $0.cover) }
            }
            try cover.start { [weak self] surface in
                self?.take { FoldableScreens(unfolded: $0.unfolded, cover: surface) }
            }
        } catch {
            stop()
            throw error
        }
        let watch = hinge.watch { [weak self] angle in
            self?.repose { $0.heard(angle) }
        }
        let sweeps = hinge.watchSweeps { [weak self] event in self?.follow(event) }
        lock.withLock {
            self.watch = watch
            self.sweeps = sweeps
        }
    }

    /// Called on the folding thread before and after the motor plays the
    /// sweep, so the posing itself happens on the render queue.
    private func follow(_ event: HingeSweepEvent) {
        let now = self.now()
        lock.withLock {
            guard !isStopped else { return }
            switch event {
            case .began(let sweep): posed.began(sweep, at: now)
            case .ended(let delivery): posed.ended(delivery)
            }
        }
        switch event {
        case .began: startTicking()
        case .ended: queue.async { [weak self] in self?.repose() }
        }
    }

    private func startTicking() {
        lock.withLock {
            guard !isStopped, ticker == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: HingeSweep.frameInterval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            ticker = timer
            timer.resume()
        }
    }

    private func tick() {
        repose()
        lock.withLock {
            guard isStopped || !posed.isMoving(at: now()) else { return }
            ticker?.cancel()
            ticker = nil
        }
    }

    /// Pose the book where `PosedHinge` has it now, after `change`, and
    /// recompose — unless the book is already there.
    private func repose(_ change: (inout PosedHinge) -> Void = { _ in }) {
        let moved: Bool = posing.withLock {
            let next = lock.withLock { () -> Double? in
                guard !isStopped else { return nil }
                change(&posed)
                let degrees = posed.degrees(at: now())
                guard degrees != hingeDegrees else { return nil }
                hingeDegrees = degrees
                return degrees
            }
            guard let next else { return false }
            scene.update(hingeDegrees: next)
            onPose(FoldablePose(hingeDegrees: next))
            return true
        }
        if moved { refresh() }
    }

    func stop() {
        let (watch, sweeps, ticker) = lock.withLock {
            isStopped = true
            pending = false
            latest = FoldableScreens(unfolded: nil, cover: nil)
            delivery = nil
            frameDelivery = nil
            defer {
                self.watch = nil
                self.sweeps = nil
                self.ticker = nil
            }
            return (self.watch, self.sweeps, self.ticker)
        }
        pump?.stop(waitForDelivery: false)
        ticker?.cancel()
        sweeps?.cancel()
        watch?.cancel()
        unfolded.stop()
        cover.stop()
    }

    /// Recompose the retained frames after a pose or camera change.
    func refresh() {
        take { $0 }
    }

    private func take(_ update: (FoldableScreens) -> FoldableScreens) {
        let shouldStart = lock.withLock {
            guard !isStopped else { return false }
            latest = update(latest)
            guard isPosed, latest.unfolded != nil || latest.cover != nil else { return false }
            if fps != nil { return true }
            if isRendering {
                pending = true
                return false
            }
            isRendering = true
            return true
        }
        guard shouldStart else { return }
        if let pump { pump.offer(()) } else { queue.async { [weak self] in self?.render() } }
    }

    private func render() {
        while true {
            let screens = lock.withLock { latest }
            do {
                if lock.withLock({ frameDelivery != nil }) {
                    let rendered = try scene.renderFrame(screens: screens)
                    let callback = lock.withLock { isStopped ? nil : frameDelivery }
                    callback?(.success(rendered))
                } else {
                    let rendered = try scene.render(screens: screens)
                    let callback = lock.withLock { isStopped ? nil : delivery }
                    callback?(rendered)
                }
            } catch {
                let callback = lock.withLock { isStopped ? nil : frameDelivery }
                callback?(.failure(error))
                log("3D foldable frame skipped: \(error)")
            }
            let again = lock.withLock {
                guard !isStopped, pending else {
                    pending = false
                    isRendering = false
                    return false
                }
                pending = false
                return true
            }
            if !again { return }
        }
    }
}
