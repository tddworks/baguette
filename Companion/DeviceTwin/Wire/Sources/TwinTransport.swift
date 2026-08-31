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
    private var textInFlightCount = 0
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

    /// High-rate text (motion samples): a BOUNDED in-flight window.
    /// Awaiting each send's completion serializes delivery at one
    /// sample per RTT (~33 Hz on typical Wi-Fi — measured); an
    /// unbounded queue turns a stall into a burst of stale arrivals.
    /// So up to `textWindow` sends pipeline freely (TCP keeps them
    /// ordered), and beyond that the newest pending line replaces any
    /// unsent one — each sample carries its timestamp, so dropped
    /// ones cost nothing to the replayed trajectory.
    public func send(coalescedText text: String) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if textInFlightCount >= Self.textWindow {
            pendingText = text
            lock.unlock()
            return
        }
        textInFlightCount += 1
        lock.unlock()
        sendTextNow(text)
    }

    private static let textWindow = 3

    private func sendTextNow(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if let error { NSLog("TwinTransport coalesced send failed: \(error)") }
            guard let self else { return }
            self.lock.lock()
            let next = self.closed ? nil : self.pendingText
            self.pendingText = nil
            if next == nil { self.textInFlightCount -= 1 }
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
