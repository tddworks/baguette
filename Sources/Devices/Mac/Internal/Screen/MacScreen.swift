import BaguetteDevice
import Foundation
import IOSurface

/// A Mac display's screen, through ScreenCaptureKit — as a simulator's: each
/// complete picture handed on as a BGRA surface, at the display's capture
/// size. An unchanged picture is never handed on; the stream's own refresh
/// repeats the last. When the feed ends (sleep, a display change), the
/// screen is still there: the feed starts again, a second later, for as long
/// as the screen is started.
final class MacScreen: Screen, @unchecked Sendable {
    private let display: MacDisplayInfo
    private let feed: any DisplayFeed
    private let pause: @Sendable (TimeInterval) -> Void
    private let lock = NSLock()
    private var onFrame: (@Sendable (IOSurface) -> Void)?

    init(display: MacDisplayInfo, feed: any DisplayFeed,
         pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.display = display
        self.feed = feed
        self.pause = pause
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock { self.onFrame = onFrame }
        do { try open() } catch { stop(); throw error }
    }

    func stop() {
        lock.withLock { onFrame = nil }
        feed.stop()
    }

    private var started: Bool { lock.withLock { onFrame != nil } }

    private func open() throws {
        try feed.start(display: display.id, size: display.captureSize.pixels,
                       onPicture: { [weak self] picture in self?.hand(picture) },
                       onEnd: { [weak self] in self?.reopen() })
    }

    private func hand(_ picture: FeedPicture) {
        guard picture.complete, let surface = picture.surface,
              let onFrame = lock.withLock({ onFrame }) else { return }
        onFrame(surface)
    }

    /// Again, a second from now, while started; again after that if it fails.
    private func reopen() {
        pause(1)
        guard started else { return }
        do { try open() } catch { reopen() }
    }
}
