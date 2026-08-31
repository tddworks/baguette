import Foundation

/// One WebSocket to the baguette host. Text lines (hello / format)
/// are sent in order; binary chunks ride a latest-frame-drop path —
/// while one send is in flight the newest pending chunk replaces any
/// unsent one, so a Wi-Fi hiccup costs freshness, never a growing
/// queue. That rule is what keeps the broadcast extension inside its
/// memory ceiling on a bad network.
public final class TwinTransport: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var chunkInFlight = false
    private var pendingChunk: Data?
    private var textInFlight = false
    private var pendingText: String?
    private var closed = false

    public init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
    }

    public func connect() {
        task.resume()
        receiveLoop()
    }

    public func send(text: String) {
        task.send(.string(text)) { error in
            if let error { NSLog("TwinTransport text send failed: \(error)") }
        }
    }

    /// Latest-drop for high-rate text (motion samples): while one send
    /// is in flight the newest pending line replaces any unsent one.
    /// Queuing stale samples is what turns a brief stall into a burst
    /// of late arrivals — and each sample carries its timestamp, so
    /// dropped ones cost nothing to the replayed trajectory.
    public func send(coalescedText text: String) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if textInFlight {
            pendingText = text
            lock.unlock()
            return
        }
        textInFlight = true
        lock.unlock()
        sendTextNow(text)
    }

    private func sendTextNow(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if let error { NSLog("TwinTransport coalesced send failed: \(error)") }
            guard let self else { return }
            self.lock.lock()
            let next = self.closed ? nil : self.pendingText
            self.pendingText = nil
            self.textInFlight = next != nil
            self.lock.unlock()
            if let next { self.sendTextNow(next) }
        }
    }

    public func send(chunk: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if chunkInFlight {
            pendingChunk = chunk
            lock.unlock()
            return
        }
        chunkInFlight = true
        lock.unlock()
        sendNow(chunk)
    }

    public func close() {
        lock.lock()
        closed = true
        pendingChunk = nil
        pendingText = nil
        lock.unlock()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func sendNow(_ chunk: Data) {
        task.send(.data(chunk)) { [weak self] error in
            if let error { NSLog("TwinTransport chunk send failed: \(error)") }
            guard let self else { return }
            self.lock.lock()
            let next = self.closed ? nil : self.pendingChunk
            self.pendingChunk = nil
            self.chunkInFlight = next != nil
            self.lock.unlock()
            if let next { self.sendNow(next) }
        }
    }

    /// The host only ever sends small JSON acks; drain them so the
    /// socket's receive window never stalls.
    private func receiveLoop() {
        task.receive { [weak self] result in
            switch result {
            case .success:
                self?.receiveLoop()
            case .failure(let error):
                NSLog("TwinTransport receive ended: \(error)")
            }
        }
    }
}
