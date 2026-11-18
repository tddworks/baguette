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
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var subscribers: [UUID: @Sendable (IOSurface) -> Void] = [:]
    // Byte-role viewers: H.264 passthrough, each with its own
    // keyframe gate (false until a keyframe followed their attach or
    // the latest description).
    private var byteSubscribers: [UUID: (sink: @Sendable (Data) -> Void, open: Bool)] = [:]
    private var latest: IOSurface?
    private var descriptionChunk: Data?
    private var descriptionPayload: Data?
    private var configured = false
    // Deltas that follow a (re)configure reference frames this decoder
    // never saw; VideoToolbox rejects them (-12909). Video resumes at
    // the next keyframe, exactly like a late-joining viewer.
    private var awaitingKeyframe = true
    private var closed = false
    private var published: TimeInterval?

    init(
        decoder: any H264Decoder,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.decoder = decoder
        self.now = now
    }

    /// When the hub last published a decoded frame — the gyro's render
    /// clock skips its forced refresh while mirror frames flow (the
    /// pose rides the next frame for free) and renders itself only
    /// when the source goes idle.
    var lastPublish: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return published
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
            lock.lock()
            descriptionChunk = chunk
            descriptionPayload = payload
            let wantsPixels = !subscribers.isEmpty
            // Fresh parameter sets re-gate every byte viewer too.
            for id in byteSubscribers.keys { byteSubscribers[id]?.open = false }
            let byteSinks = byteSubscribers.values.map(\.sink)
            lock.unlock()
            for sink in byteSinks { sink(chunk) }
            if wantsPixels { configureDecoder(payload) }
        case AVCCEnvelope.keyframeTag:
            lock.lock()
            let ready = configured
            awaitingKeyframe = false
            for id in byteSubscribers.keys { byteSubscribers[id]?.open = true }
            let byteSinks = byteSubscribers.values.map(\.sink)
            lock.unlock()
            for sink in byteSinks { sink(chunk) }
            guard ready else { return }
            decoder.decode(payload)
        case AVCCEnvelope.deltaTag:
            lock.lock()
            let ready = configured && !awaitingKeyframe
            let openSinks = byteSubscribers.values.filter(\.open).map(\.sink)
            lock.unlock()
            for sink in openSinks { sink(chunk) }
            guard ready else { return }
            decoder.decode(payload)
        default:
            break
        }
    }

    /// The byte role: forward the companion's own H.264 chunks — no
    /// decode, no re-encode, N viewers share the same bytes. The
    /// cached description replays on attach; video resumes at the
    /// next keyframe.
    func attachBytes(id: UUID, sink: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        byteSubscribers[id] = (sink, false)
        let replay = descriptionChunk
        lock.unlock()
        if let replay { sink(replay) }
    }

    func detachBytes(id: UUID) {
        lock.lock()
        byteSubscribers[id] = nil
        lock.unlock()
    }

    private func configureDecoder(_ payload: Data) {
        do {
            try decoder.configure(description: payload) { [weak self] surface in
                self?.publish(surface)
            }
            lock.lock()
            configured = true
            awaitingKeyframe = true
            lock.unlock()
        } catch {
            log("[device] decoder configure failed: \(error)")
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
        published = now()
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
        let firstConsumer = subscribers.isEmpty
        subscribers[id] = onFrame
        let replay = latest
        // Lazy pixels: the decoder exists only while someone needs
        // surfaces. The first consumer starts it from the cached
        // description (video resumes at the next keyframe).
        let pending = (firstConsumer && !configured) ? descriptionPayload : nil
        lock.unlock()
        if let pending { configureDecoder(pending) }
        if let replay { onFrame(replay) }
    }

    fileprivate func detach(id: UUID) {
        lock.lock()
        subscribers[id] = nil
        let idle = subscribers.isEmpty && configured
        if idle {
            configured = false
            awaitingKeyframe = true
        }
        lock.unlock()
        if idle { decoder.stop() }
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
