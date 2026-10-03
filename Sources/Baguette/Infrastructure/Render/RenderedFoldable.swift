import Foundation
import IOSurface

/// A foldable's two screens and hinge, composed through one persistent
/// 3D device scene.
///
/// Frames from either panel and hinge samples all funnel into one
/// serialized composition of the latest state — the latest frame of
/// each panel on its screen, the book posed at the latest angle. As in
/// `RenderedScreen`, at most one composition is pending, so a slow model
/// drops stale work instead of queueing it.
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
    private var frameDelivery: (@Sendable (Result<DeviceFrame, any Error>) -> Void)?
    private var isRendering = false
    private var pending = false
    private var latest = FoldableScreens(unfolded: nil, cover: nil)
    private var isStopped = true
    /// A scene starts flat. Nothing is composed until the book has been
    /// posed, or the first frame would show it open when shut.
    private var isPosed = false
    /// The hinge's own angle, as last heard (shut until it speaks).
    private var hingeDegrees: Double = 0

    /// The pose the book is shown at.
    var pose: FoldablePose {
        lock.withLock { FoldablePose(hingeDegrees: hingeDegrees) }
    }

    private let onPose: @Sendable () -> Void

    /// `onPose` runs after each hinge sample has posed the scene.
    init(
        unfolded: any Screen, cover: any Screen, hinge: any Hinge, scene: any DeviceScene,
        fps: Int? = nil, onPose: @escaping @Sendable () -> Void = {}
    ) {
        self.unfolded = unfolded
        self.cover = cover
        self.hinge = hinge
        self.scene = scene
        self.fps = fps
        self.onPose = onPose
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
            guard let self else { return }
            self.lock.withLock {
                self.hingeDegrees = angle.degrees
                self.isPosed = true
            }
            self.scene.update(hingeDegrees: angle.degrees)
            self.onPose()
            self.refresh()
        }
        lock.withLock { self.watch = watch }
    }

    func stop() {
        let watch = lock.withLock {
            isStopped = true
            pending = false
            latest = FoldableScreens(unfolded: nil, cover: nil)
            delivery = nil
            frameDelivery = nil
            defer { self.watch = nil }
            return self.watch
        }
        pump?.stop(waitForDelivery: false)
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
