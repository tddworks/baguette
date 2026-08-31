import Foundation
import IOSurface

/// The ingest hub for one connected physical device: feeds the
/// companion's AVCC chunks to the decoder (description → configure,
/// key/delta → decode) and fans decoded surfaces out to every
/// subscribed view — decode once, no matter how many streams watch.
///
/// `view()` hands out a lightweight `Screen` per stream socket, the
/// same shape `simulator.screen()` gives the stream pipeline, so
/// `MJPEGStream` / `AVCCStream` / recording bind to a physical device
/// with no changes. A view that joins late immediately receives the
/// latest decoded surface so it never stares at a blank canvas.
final class TwinScreen: @unchecked Sendable {
    private let decoder: any H264Decoder
    private let lock = NSLock()
    private var subscribers: [UUID: @Sendable (IOSurface) -> Void] = [:]
    private var latest: IOSurface?
    private var configured = false
    private var closed = false

    init(decoder: any H264Decoder) {
        self.decoder = decoder
    }

    /// One binary WebSocket message from the companion's video socket.
    /// Malformed chunks are logged and dropped — they carry no frame a
    /// viewer could miss.
    func ingest(chunk: Data) {
        guard let (tag, payload) = AVCCEnvelope.unwrap(chunk) else {
            log("[device] dropping malformed video chunk (\(chunk.count) bytes)")
            return
        }
        switch tag {
        case AVCCEnvelope.descriptionTag:
            do {
                try decoder.configure(description: payload) { [weak self] surface in
                    self?.publish(surface)
                }
                lock.lock()
                configured = true
                lock.unlock()
            } catch {
                log("[device] decoder configure failed: \(error)")
            }
        case AVCCEnvelope.keyframeTag, AVCCEnvelope.deltaTag:
            lock.lock()
            let ready = configured
            lock.unlock()
            guard ready else { return }
            decoder.decode(payload)
        default:
            break
        }
    }

    /// Tear down when the companion's video socket closes.
    func close() {
        lock.lock()
        closed = true
        subscribers.removeAll()
        latest = nil
        lock.unlock()
        decoder.stop()
    }

    /// A per-stream `Screen` over this device's decoded frames.
    func view() -> any Screen {
        TwinScreenView(hub: self)
    }

    private func publish(_ surface: IOSurface) {
        lock.lock()
        latest = surface
        let sinks = Array(subscribers.values)
        lock.unlock()
        for sink in sinks { sink(surface) }
    }

    fileprivate func attach(id: UUID, onFrame: @escaping @Sendable (IOSurface) -> Void) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        subscribers[id] = onFrame
        let replay = latest
        lock.unlock()
        if let replay { onFrame(replay) }
    }

    fileprivate func detach(id: UUID) {
        lock.lock()
        subscribers[id] = nil
        lock.unlock()
    }
}

/// One stream's subscription to the hub. Weak back-reference: the hub
/// owns the decode pipeline and outlives its views; a view surviving
/// the hub just goes silent.
private final class TwinScreenView: Screen, @unchecked Sendable {
    private weak var hub: TwinScreen?
    private let id = UUID()

    init(hub: TwinScreen) {
        self.hub = hub
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        hub?.attach(id: id, onFrame: onFrame)
    }

    func stop() {
        hub?.detach(id: id)
    }
}
