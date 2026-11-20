import Foundation

/// The `FrameSink` a viewer's own stream writes to: each AVCC envelope goes
/// to the viewer, a failed stream hangs it up. Held weakly, so a hung-up
/// viewer isn't kept alive by its stream.
final class RTPFrameSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private weak var _viewer: WebRTCViewer?

    func attach(_ viewer: WebRTCViewer) { lock.withLock { _viewer = viewer } }

    private var viewer: WebRTCViewer? { lock.withLock { _viewer } }

    func write(_ data: Data) { viewer?.show(data) }

    func fail(_ error: any Error) { viewer?.hangUp() }
}
