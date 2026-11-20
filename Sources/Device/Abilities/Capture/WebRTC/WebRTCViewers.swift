import Foundation

/// The live WebRTC (WHEP) viewers of one server, by id. It admits a browser's
/// offer with a viewer of its own, streaming the screen it is given, and lets
/// the viewer go the moment it hangs up, for whatever reason (its stream, which
/// stops its screen, goes with it). An id it doesn't know is a refusal naming it.
public final class WebRTCViewers: @unchecked Sendable {
    public enum Refusal: Error, Equatable { case unknownViewer(String) }

    /// The outside world a viewer needs, trusting the certificate its offer named.
    public typealias Connect = @Sendable (_ browserFingerprint: String) throws -> (any Datagrams, any Handshake)

    private let lock = NSLock()
    private var viewers: [String: WebRTCViewer] = [:]
    private let connect: Connect
    private let makeStream: (any FrameSink) -> any Stream
    private var timer: DispatchSourceTimer?

    /// `ticking`: how often consent and DTLS retransmission are checked; nil
    /// leaves it to whoever calls `tick(now:)`. `stream`: what a viewer is
    /// shown — H.264 at the stream socket's defaults.
    public init(
        ticking interval: TimeInterval? = 1,
        connect: @escaping Connect = WebRTCViewers.onThisMac,
        stream: @escaping (any FrameSink) -> any Stream = { sink in
            StreamFormat.avcc.makeStream(config: .default, sink: sink, quality: 0.5)
        }
    ) {
        self.connect = connect
        self.makeStream = stream
        guard let interval else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "baguette.webrtc.viewers"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick(now: Date()) }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// A UDP socket on this Mac and a BoringSSL DTLS server.
    public static let onThisMac: Connect = { fingerprint in
        let handshake = try BoringSSLHandshake()
        handshake.expect(fingerprint)
        return (try UDPDatagrams(), handshake)
    }

    public var count: Int { lock.withLock { viewers.count } }

    /// A viewer for the browser whose WHEP `offer` this is, its own stream
    /// started on `screen`: its id, and the SDP answer. Throws the offer's
    /// refusal, or why the viewer couldn't be connected or started.
    public func admit(offer: String, on screen: any Screen) throws -> (id: String, answer: String) {
        let description = try SessionDescription(offer: offer)
        let (datagrams, handshake) = try connect(description.browserFingerprint)
        let viewer = WebRTCViewer(offer: description, datagrams: datagrams, handshake: handshake, stream: makeStream)
        do {
            try viewer.start(on: screen)
        } catch {
            viewer.hangUp()
            throw error
        }
        let id = UUID().uuidString.lowercased()
        lock.withLock { viewers[id] = viewer }
        viewer.onHangUp { [weak self] in self?.lock.withLock { self?.viewers[id] = nil } }
        return (id, viewer.answer)
    }

    public func find(_ id: String) throws -> WebRTCViewer {
        guard let viewer = lock.withLock({ viewers[id] }) else { throw Refusal.unknownViewer(id) }
        return viewer
    }

    public func hangUp(_ id: String) throws { try find(id).hangUp() }

    /// Time passing, for every viewer: those whose browsers went quiet hang up.
    public func tick(now: Date) {
        lock.withLock { Array(viewers.values) }.forEach { $0.tick(now: now) }
    }
}
