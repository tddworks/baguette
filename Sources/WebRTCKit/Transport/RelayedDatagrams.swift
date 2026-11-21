import Foundation

/// A viewer's socket with a TURN relay beside it (RFC 8656): what a peer sends
/// to the relayed address arrives as a Data indication from the server and is
/// handed on as if it came from the peer; an answer to a peer last heard
/// through the relay goes back through it, wrapped in a Send indication; and
/// everyone else is reached directly, as before. So the sender above it never
/// knows which path a browser took. It keeps the allocation and its
/// permissions alive (refreshed at half their lifetimes) and gives the
/// allocation up when closed.
public final class RelayedDatagrams: Datagrams, TURNExchange, @unchecked Sendable {
    public let allocation: TURNAllocation

    private let inner: any Datagrams
    private let lock = NSLock()
    private var handler: (@Sendable (Data, DatagramAddress) -> Void)?
    /// Peers whose last datagram came through the relay: answered through it.
    private var viaRelay: Set<DatagramAddress> = []
    private var waiting: [[UInt8]: (Pending, DispatchSemaphore)] = [:]
    private var permitted: [DatagramAddress] = []
    private var timer: DispatchSourceTimer?

    /// Permissions last 300 s (RFC 8656 §9): renewed well before.
    private static let permissionRefresh: TimeInterval = 240

    public init(over inner: any Datagrams, allocation: TURNAllocation) {
        self.inner = inner
        self.allocation = allocation
        inner.onReceive { [weak self] data, from in self?.receive(data, from: from) }
    }

    /// Keeps the allocation and its permissions alive until `close()`.
    public func keepAlive() {
        let every = min(Double(allocation.lifetime) / 2, Self.permissionRefresh)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "baguette.webrtc.turn"))
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            _ = allocation.refresh(lifetime: allocation.lifetime, exchange: self, timeout: 1)
            let peers = lock.withLock { permitted }
            if !peers.isEmpty { _ = allocation.permit(peers, exchange: self, timeout: 1) }
        }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    /// Let `peers` through the relay — the browser's addresses, before it checks.
    public func permit(_ peers: [DatagramAddress]) -> Bool {
        lock.withLock { permitted = Array(Set(permitted + peers)) }
        return allocation.permit(peers, exchange: self, timeout: 1)
    }

    // MARK: - Datagrams

    public var addresses: [DatagramAddress] { inner.addresses }

    public func send(_ datagram: Data, to address: DatagramAddress) {
        guard lock.withLock({ viaRelay.contains(address) }) else { return inner.send(datagram, to: address) }
        let wrapped = TURNMessage.send(datagram, to: address, transactionID: TURNAllocation.transactionID())
        inner.send(wrapped, to: allocation.server.address)
    }

    public func onReceive(_ handler: @escaping @Sendable (Data, DatagramAddress) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func close() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        _ = allocation.refresh(lifetime: 0, exchange: self, timeout: 0.2)
        inner.close()
    }

    // MARK: - what arrives

    private func receive(_ data: Data, from: DatagramAddress) {
        if from == allocation.server.address, let message = TURNReply(data) {
            if message.type == TURNMessage.dataIndication {
                guard let peer = message.peers.first, let payload = message.data else { return }
                let handler = lock.withLock { () -> (@Sendable (Data, DatagramAddress) -> Void)? in
                    viaRelay.insert(peer)
                    return self.handler
                }
                handler?(payload, peer)
            } else if let (reply, answered) = lock.withLock({ waiting[message.transactionID] }), reply.set(message) {
                answered.signal()
            }
            return
        }
        let handler = lock.withLock { () -> (@Sendable (Data, DatagramAddress) -> Void)? in
            viaRelay.remove(from)
            return self.handler
        }
        handler?(data, from)
    }

    // MARK: - TURNExchange

    func ask(_ request: Data, transactionID: [UInt8], timeout: TimeInterval) -> TURNReply? {
        let reply = Pending(), answered = DispatchSemaphore(value: 0)
        lock.withLock { waiting[transactionID] = (reply, answered) }
        defer { _ = lock.withLock { waiting.removeValue(forKey: transactionID) } }
        for _ in 0..<2 {
            inner.send(request, to: allocation.server.address)
            if answered.wait(timeout: .now() + timeout / 2) == .success { return reply.value }
        }
        return nil
    }
}
