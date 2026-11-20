import Foundation

/// The `FrameSink` a viewer's own stream writes to: each AVCC envelope goes
/// to the viewer, a failed stream hangs it up (off the stream's queue). Held weakly, so a hung-up
/// viewer isn't kept alive by its stream.
final class RTPFrameSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private weak var _viewer: WebRTCViewer?

    func attach(_ viewer: WebRTCViewer) { lock.withLock { _viewer = viewer } }

    private var viewer: WebRTCViewer? { lock.withLock { _viewer } }

    func write(_ data: Data) { viewer?.show(data) }

    /// A stream fails from its own encoding queue, and stopping it waits on that
    /// queue (`AVCCStream.stop` does `queue.sync`): hanging up right here would
    /// deadlock, which libdispatch traps. So the hang-up happens off that queue.
    func fail(_ error: any Error) {
        guard let viewer else { return }
        DispatchQueue.global().async { viewer.hangUp() }
    }
}
