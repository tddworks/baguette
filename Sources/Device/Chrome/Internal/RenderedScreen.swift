import Foundation
import IOSurface

/// A screen whose frames are composed through one persistent 3D device scene.
///
/// Rendering is serialized away from the screen's frame callback, the newest
/// surface one at a time (`LatestFrame`), so a slow model drops stale frames
/// instead of blocking capture or growing a queue.
public final class RenderedScreen: DeviceFrames, @unchecked Sendable {
    private let source: any Screen
    private let scene: any DeviceScene
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.baguette.rendered-screen",
        qos: .userInteractive
    )
    private let fps: Int?
    private lazy var renders = LatestFrame<IOSurface>(queue: queue, fps: fps ?? 0) { [weak self] surface, ready in
        self?.render(surface)
        ready()
    }
    private var delivery: (@Sendable (IOSurface) -> Void)?
    private var frameDelivery: (@Sendable (Result<DeviceFrame, any Error>) -> Void)?
    /// The simulator's last frame, recomposed when the pose changes (`refresh`).
    private var latestSurface: IOSurface?
    private var isStopped = true

    public init(source: any Screen, scene: any DeviceScene, fps: Int? = nil) {
        self.source = source
        self.scene = scene
        self.fps = fps
    }

    public func startFrames(onFrame: @escaping @Sendable (Result<DeviceFrame, any Error>) -> Void) throws {
        lock.withLock { frameDelivery = onFrame }
        try start { _ in }
    }

    public func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock {
            delivery = onFrame
            isStopped = false
        }
        renders.start()
        do {
            try source.start { [weak self] surface in
                self?.enqueue(surface)
            }
        } catch {
            lock.withLock {
                delivery = nil
                frameDelivery = nil
                isStopped = true
            }
            renders.stop(waitForDelivery: false)
            throw error
        }
    }

    public func stop() {
        lock.withLock {
            isStopped = true
            latestSurface = nil
            delivery = nil
            frameDelivery = nil
        }
        renders.stop(waitForDelivery: false)
        source.stop()
    }

    private func enqueue(_ surface: IOSurface) {
        let running = lock.withLock {
            guard !isStopped else { return false }
            latestSurface = surface
            return true
        }
        if running { renders.offer(surface) }
    }

    /// Recompose the retained simulator frame after an in-place pose change.
    public func refresh() {
        guard let surface = lock.withLock({ isStopped ? nil : latestSurface }) else {
            return
        }
        enqueue(surface)
    }

    private func render(_ current: IOSurface) {
        do {
            if lock.withLock({ frameDelivery != nil }) {
                let rendered = try scene.renderFrame(screen: current)
                let callback = lock.withLock { isStopped ? nil : frameDelivery }
                callback?(.success(rendered))
            } else {
                let rendered = try scene.render(screen: current)
                let callback = lock.withLock { isStopped ? nil : delivery }
                callback?(rendered)
            }
        } catch {
            let callback = lock.withLock { isStopped ? nil : frameDelivery }
            callback?(.failure(error))
            log("3D screen frame skipped: \(error)")
        }
    }
}
